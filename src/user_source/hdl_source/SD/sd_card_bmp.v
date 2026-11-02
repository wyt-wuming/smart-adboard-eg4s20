
//==============================================================================
//  文件名  : sd_card_bmp.v
//  模块名  : sd_card_bmp
//  功能    : TF 卡 BMP 图片通道 —— 扫描 / 装载 / 轮播调度 / 双缓冲切换
//  时钟域  : sd_card_clk（100MHz）
//  上游    : sd_card_top（扇区数据，经 sd_bus_arbiter 仲裁后接入）
//  下游    : frame_fifo_write → SDRAM 帧缓存
//------------------------------------------------------------------------------
//  【模块职责】
//    1. 开机扫描 TF 卡，找到所有 BMP 图（最多 8 张，记录各自扇区号）
//    2. 按轮播周期（I_period_sec = 5~30 秒）自动换图；按键可手动切图
//    3. 装载流程：bmp_read 读原始像素 → img_scaler 等比缩放 → 写帧缓存
//    4. 双缓冲调度（write_buf_idx / disp_buf_idx），装载期间画面不闪不撕
//    5. 缩放值（I_zoom_pct）变化时自动重载当前图，带 400ms 节流
//
//  【三个必须保留的设计细节（改动会出 bug）】
//    ★1. 轮播周期用"1 秒节拍 + 秒计数器"实现，不能写成"周期 × 100MHz"
//        直接比较：30 秒 × 100MHz = 3.0e9 超出 32 位有符号整数范围（2.147e9）
//        → 溢出失效。
//    ★2. 按键输入 key_next 是外层 key_ctrl_fsm 消抖后的**单拍脉冲**，
//        本模块内部不能再消抖（再消抖一次会把 20ns 宽的脉冲漏掉 → 按键失效）。
//    ★3. 状态输出（O_load_busy / O_auto_play_en / O_img_idx / O_img_found_count）
//        供转场 fade_ctrl 和 OSD 显示使用，改动时序时要一起检查。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,              // sd_card_clk = 100MHz
    input                       rst,              // 高有效复位
    input                       key_next,         // ★ 手动切下一张（单拍脉冲，勿再消抖）
    input                       auto_play_ext,    // ★ 自动轮播开关（电平），来自拨码开关 SW2
    input  [7:0]                I_period_sec,     // ★ 轮播周期（秒），来自 key_ctrl_fsm
    // ★ 画面缩放百分比（50~200，100=原图大小），由 key_ctrl_fsm 经 cfg_cdc 送过来。
    //   它一变就要"重新装载当前这张图"（因为缩放只能在装载时对像素流做），
    //   见下面的"缩放值变化 → 重载"逻辑。
    input  [7:0]                I_zoom_pct,
    output [3:0]                state_code,       // bmp_read 状态码（送数码管）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,    // 是否已有可显示的画面

    // ---- ★ 给 OSD / 转场模块用的状态输出 ----
    output                      O_load_busy,      // 正在装载新图（转场淡出用）
    output                      O_img_switch,     // ★ 1 = 正在装载"另一张图"（换图才转场，缩放重载不算）
    output                      O_auto_play_en,   // 自动轮播是否开启（OSD 显示用）
    output [2:0]                O_img_idx,        // 当前显示第几张（OSD 显示用）★ 2→3 位
    output [2:0]                O_img_found_count,// 共找到几张图（OSD 显示用）

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,

    // ---- ★ SD 卡总线改为从外部接入（sd_card_top 提到顶层）----
    //   原因：图片读取和音频读取要共用同一条 SPI 总线，
    //         所以 sd_card_top 必须在顶层只例化一份，由 sd_bus_arbiter 分配使用权。
    //   本模块从此不再直接驱动 SD 引脚。
    input                       sd_init_done,          // SD 卡初始化完成
    output                      sd_sec_read,           // 请求读一个扇区
    output [31:0]               sd_sec_read_addr,      // 要读的扇区地址
    input  [7:0]                sd_sec_read_data,      // 读回的字节
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end        // 一个扇区读完（单拍）
);

wire key_next_press;

// ★ sd_sec_read* / sd_init_done 已提升为模块端口，此处不再声明
// ★ 这三条线是 bmp_read 的**原始**输出（未缩放），
//   先送进 img_scaler 做等比缩放，缩放后的结果才接到 write_en/write_data。
wire             src_bmp_wr;        // 源图像素有效
wire [23:0]      src_bmp_data;      // 源图像素颜色
wire [15:0]      src_img_w;         // 源图宽度
wire [15:0]      src_img_h;         // 源图高度
wire             src_frame_start;   // 新图第一个像素

wire             scaled_wr;         // 缩放后的像素有效
wire [23:0]      scaled_data;       // 缩放后的像素颜色
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
// ★ 自动轮播开关改成"外部电平"：由拨码开关 SW2 直接控制，
//   不再是内部按键翻转，所以用 wire 而不是 reg
wire             auto_play_en = auto_play_ext;
// ★ 轮播周期计数：改成"1 秒节拍 + 秒计数器"
//   原实现是 reg [31:0] auto_cnt + 与 CLK_FREQ_HZ-1 比较（写死 1 秒）。
//   改成秒计数器后：① 周期可通过 I_period_sec 配置 ② 最长 30 秒也不会溢出
reg [26:0]       sec_div_cnt;      // 1 秒分频计数器（100MHz 时钟下数到 99_999_999）
reg              tick_1sec;        // 1 秒单拍脉冲
reg [15:0]       auto_sec_cnt;     // 自动轮播已累计的秒数
reg [2:0]        img_found_count;
// ★ 图片编号从 2 位加宽到 3 位（原来只能数到 3，只能放 4 张图）
reg [2:0]        img_idx;              // 当前真正显示中的图片编号 0~6
reg [2:0]        load_idx;             // 当前正在写入的图片编号 0~6
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
// ★ 第 5~8 个槽位（原来只有 4 个，卡上多的图轮不到）
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg [31:0]       img_sector6;
reg [31:0]       img_sector7;
reg              next_req_pending;

// ★ 装载超时兜底（2026-10-06 加，阈值当天修正过）
//   用途：万一装载因为异常永远不完成（卡读失败 / 帧缓存写不满…），
//        强制释放 load_busy，避免整个系统永久卡在"装载中"。
//
//   ★★ 阈值必须足够大，否则会"自己打断自己"：
//      一张 640x480 的 BMP = 921654 字节 = 1800 个扇区，
//      连续 CMD17 读约 184µs/扇区（见 sd_bus_arbiter 注释）→ 整张约 350ms。
//      （历史教训：曾设成 2.7 秒时被打断过 → load_busy 被清 →
//        系统重新发起装载 → 又被打断，无限循环，
//        表现是数码管最左位一直停在 4、画面永远全黑。）
//   现在给到 30 秒，正常装载 350ms 只用掉零头，纯粹当保险。
localparam [31:0] LOAD_TIMEOUT_MAX = 32'd3_000_000_000;   // 30 秒 @100MHz
reg [31:0]       load_timeout;
reg              load_busy;

// ★ 画面缩放：缩放值一变就重载当前图（带 400ms 节流，防按键连发时疯狂重载）
//   100MHz 下 400ms = 40_000_000 拍，27 位计数器够（最大 1.34 亿）
localparam [26:0] RELOAD_GAP = 27'd40_000_000;   // 两次重载之间至少隔 400ms

// ★ "静默重载"（2026-10-06 加）
//   每重载一次都要把源图从 SD 卡重读一遍（约 350ms），
//   如果"每按一下就重载一次"，从 100% 调到 50% 要按 10 次 → 等约 4 秒（350ms 装载 + 400ms 节流），
//   而且长按连发时装载里穿插重载，画面一直卡在"装载中"。
//   改成：连按期间只更新数值、并不断重置这个静默计时器；
//        松手（数值 300ms 不变）之后才真正重载一次。
//   同样的操作降到约 0.7 秒（300ms 静默 + 350ms 装载）。
//   （2026-10-31：静默期由 500ms 缩短到 300ms —— 单按响应由约 750ms
//     降到约 650ms；连按间隔 150ms 本来走 400ms 强制兜底，行为不变。）
localparam [26:0] ZOOM_QUIET_GAP = 27'd30_000_000;   // 300ms 静默 @100MHz

// ★ "强制刷新兜底"（2026-10-06 排查"缩放跳跃异常"后加）
//   静默期能防"连按时疯狂重载"，但也会把长按期间的刷新全挡死：
//   长按每 150ms 连发一次，zoom_quiet 不停被清零 → 永远到不了静默期
//   → 重载永远不发起 → 画面死卡（系统空闲，数码管位5=1），
//   松手后 500ms 静默 + 一次装载才突然跳到目标，体感"坏掉"。
//   兜底：zoom_pending 置 1 后单独计时，连按不清零；
//   满 400ms 还没能重载就强制用当前值刷一次。
//   节奏推算：装载 350ms（期间连发把 force 重新计时）+ 400ms 兜底
//   ≈ 550ms 刷一档，每档约 3~4 个步长（18%），画面慢半拍跟手。
//   为什么 400ms 而不是更小：reload_ok 节流本身就是 400ms，再小也快不了；
//   且 SD 卡被图片占用 64% 时，音频靠扇区级仲裁的"告急插队"
//   （sd_bus_arbiter wav_urgent，每个扇区 184µs 后就轮得到）不会断音。
localparam [26:0] ZOOM_FORCE_GAP = 27'd40_000_000;   // 连按 400ms 强制刷新 @100MHz
reg [26:0]       zoom_quiet;      // 距上次缩放值变化过了多久
reg [26:0]       zoom_force_cnt;  // ★ zoom_pending 已持续多久（连按不清零）
reg [7:0]        zoom_d;          // 上一拍的缩放值（用来检测变化）
reg              zoom_pending;    // 1 = 缩放值变过、还没重载
reg              reload_ok;       // 1 = 允许重载（节流门闩）
reg [26:0]       reload_cnt;      // 节流计时

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
// ★ 位宽必须是 3 位（0~7）：原来写成 2 位，而 next_index_limited() 返回 3 位，
//   最高位被截断 —— 图片超过 4 张时，"下一张"算出来的索引 4/5/6/7 会被截成
//   0/1/2/3，表现就是第 5 张之后切图错乱（切回第 1 张）。
//   这是当初"4 张扩到 8 张"时漏改的一处。
wire [2:0] next_from_current;

// ★ 写入帧缓存的像素改为"缩放后"的数据
assign write_en   = scaled_wr;
assign write_data = {scaled_data[23:16], scaled_data[15:8], scaled_data[7:0], 8'b0};
//--------------------------------------------------------------------------
// ★ 自动轮播计时：1 秒节拍 + 秒计数
//   原来：assign auto_tick = (auto_cnt == (CLK_FREQ_HZ - 1));   // 写死 1 秒
//   现在：先产生 1 秒节拍，再与外部传入的 I_period_sec 比较
//   好处：① 满足赛题"轮播周期可配置" ② 30 秒也不会溢出 32 位整数
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sec_div_cnt <= 27'd0;
        tick_1sec   <= 1'b0;
    end else if (sec_div_cnt >= CLK_FREQ_HZ - 1) begin
        sec_div_cnt <= 27'd0;
        tick_1sec   <= 1'b1;              // 满 1 秒，输出一拍
    end else begin
        sec_div_cnt <= sec_div_cnt + 27'd1;
        tick_1sec   <= 1'b0;
    end
end

// 周期目标值（防御处理：若外部给 0 则按 1 秒算，避免减 1 后下溢）
wire [15:0] period_target = (I_period_sec == 8'd0) ? 16'd1 : {8'b0, I_period_sec};

assign auto_tick  = (auto_sec_cnt >= (period_target - 16'd1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

//--------------------------------------------------------------------------
// ★ 原例程在这里例化两个 key_press_debounce 做按键消抖。
//   现在按键消抖与长短按/双击解析已由外层的 key_ctrl_fsm + key_press_event
//   完成，送进来的是"单拍脉冲"（宽度 1 个时钟周期），必须直接使用。
//
//   ★ 若在这里再消抖一次：20ns 宽的脉冲会被 2 级同步器采样到，
//     但消抖计数器要求电平"连续稳定 20ms"，单拍脉冲根本达不到，
//     结果是 press_pulse 永远不产生 —— 按键完全失效！
//     这是本次改造中最隐蔽、最容易踩的坑，务必保留此注释。
//--------------------------------------------------------------------------
//--------------------------------------------------------------------------
// ★ 按键脉冲跨时钟域同步
//   key_next 是从 50MHz 的 clk 域送过来的"单拍脉冲"（宽 20ns），
//   而本模块工作在 100MHz 的 sd_card_clk 域。
//   直接采样属于跨时钟域，偶尔会因亚稳态漏掉脉冲 ——
//   现象就是"按了按键但图片没反应"。
//
//   正确做法：先打 2 拍同步到本时钟域，再做上升沿检测，得到干净的单拍脉冲。
//   20ns 的脉冲在 100MHz（周期 10ns）下至少横跨一个完整时钟沿，
//   所以 2 级同步器一定能采到，不会再丢。
//--------------------------------------------------------------------------
reg key_next_s0, key_next_s1, key_next_s2;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_next_s0 <= 1'b0;
        key_next_s1 <= 1'b0;
        key_next_s2 <= 1'b0;
    end else begin
        key_next_s0 <= key_next;
        key_next_s1 <= key_next_s0;
        key_next_s2 <= key_next_s1;
    end
end

assign key_next_press = key_next_s1 & ~key_next_s2;   // 上升沿 → 干净的单拍脉冲

// ★ 原来只支持 4 张图（写死 4 个 case），现在改成"按实际找到的张数
//   自动环绕"，最大 8 张。这样卡上放几张就轮几张，加图减图都不用改代码。
function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        // 只有 0 张 或 已经到最后一个 → 回到 0；否则 +1
        if ((count == 3'd0) || ((cur + 3'd1) >= count))
            next_index_limited = 3'd0;
        else
            next_index_limited = cur + 3'd1;
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            3'd6: sector_lut = img_sector6;
            default: sector_lut = img_sector7;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_sec_cnt          <= 16'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        display_valid         <= 1'b0;
        zoom_d                <= 8'd100;
        zoom_pending          <= 1'b0;
        zoom_quiet            <= 27'd0;
        zoom_force_cnt        <= 27'd0;
        reload_ok             <= 1'b1;
        reload_cnt            <= 27'd0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        //------------------------------------------------------------------
        // ★ 缩放值变化检测 + 400ms 节流
        //   缩放只能在"装载"时对像素流做（显示端是顺序流式读 SDRAM，
        //   没法随机访问），所以缩放值一变就必须重载当前这张图。
        //   而按键长按每 150ms 就连发一次，若不节流会疯狂重载
        //   （一次装载约 350ms），画面会一直卡在装载中 —— 所以节流。
        //
        //   zoom_pending：只要值变过就置 1（连发期间不漏记），
        //                 真正发起重载时才清零 → 松手后画面一定是新比例。
        //   reload_ok   ：节流门闩，发起重载时清零，400ms 后自动置 1。
        //------------------------------------------------------------------
        // ★ 缩放值检测 + 静默计时（连按时不断重置，停手 300ms 后才允许重载）
        if (I_zoom_pct != zoom_d) begin
            zoom_pending <= 1'b1;
            zoom_quiet   <= 27'd0;               // 数值刚变 → 静默计时清零
        end else if (zoom_quiet < ZOOM_QUIET_GAP) begin
            zoom_quiet <= zoom_quiet + 27'd1;    // 数值稳定了 → 开始累计静默时间
        end
        zoom_d <= I_zoom_pct;

        // ★ 强制刷新兜底：pending 一置位就开始计时，连按期间不清零。
        //   静默期把长按期间的刷新全挡死时，满 800ms 强制用当前值刷一次。
        //   （读的是 pending 旧值：重载发起那拍 pending 还是 1，计数器继续；
        //    下一拍 pending 变 0，这里就自动清零，不需要显式复位。）
        if (zoom_pending)
            zoom_force_cnt <= (zoom_force_cnt < ZOOM_FORCE_GAP)
                              ? zoom_force_cnt + 27'd1 : zoom_force_cnt;
        else
            zoom_force_cnt <= 27'd0;

        if (reload_ok)
            reload_cnt <= 27'd0;
        else if (reload_cnt >= RELOAD_GAP)
            reload_ok  <= 1'b1;
        else
            reload_cnt <= reload_cnt + 27'd1;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_sec_cnt          <= 16'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 8 张图的起始 sector（★ 原来只存 4 张）
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    3'd5: img_sector5 <= scan_found_sector;
                    3'd6: img_sector6 <= scan_found_sector;
                    default: img_sector7 <= scan_found_sector;
                endcase

                if (img_found_count < 3'd7)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 装载计时：load_busy 期间逐拍递增，空闲时清零
            // ★ 位宽必须是 32 位：若写成 28'd1，加法会在 28 位里回绕
            //   （28 位最大 2.68 亿 = 2.7 秒），计数器永远到不了 30 亿这个阈值。
            if (!load_busy)
                load_timeout <= 32'd0;
            else if (load_timeout < LOAD_TIMEOUT_MAX)
                load_timeout <= load_timeout + 32'd1;

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_ready)
                source_done_seen <= 1'b1;

            // 只有真正收到 write_finish_toggle 脉冲，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_finish_pulse) begin
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                // ★ 自动轮播现在完全由拨码开关 SW2 控制（外部电平），
                //   所以这里不再自动开启，也不需要按键翻转逻辑。
            end
            // ★ 装载超时兜底：万一装载因为某种原因永远不完成
            //   （卡读失败、帧缓存没写满、SD 通信中断…），
            //   强制释放 load_busy，让系统能继续响应按键，而不是永久黑屏卡死。
            else if (load_busy && (load_timeout >= LOAD_TIMEOUT_MAX)) begin
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_sec_cnt          <= 16'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // ★ 自动轮播开关现在由拨码开关 SW2 直接控制（电平信号），
                //   不再需要"按键翻转"逻辑。
                //   注意：下面自动计时条件里包含 auto_play_en，
                //   所以拨到 OFF 时 auto_sec_cnt 会被清零；
                //   再拨回 ON 时计时从 0 重新开始，行为符合直觉。

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_sec_cnt <= 16'd0;              // 周期到，计数归零
                    else if (tick_1sec)
                        auto_sec_cnt <= auto_sec_cnt + 16'd1;// ★ 每满 1 秒才加 1
                end else begin
                    auto_sec_cnt <= 16'd0;                  // 不满足轮播条件时暂停计时
                end

                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 3'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_sec_cnt     <= 16'd0;
                    zoom_pending     <= 1'b0;   // ★ 这次装载已经用了最新缩放值
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_sec_cnt     <= 16'd0;
                    zoom_pending     <= 1'b0;   // ★ 这次装载已经用了最新缩放值
                end
                // ★ 缩放值变化 → 重载"当前这一张"
                //   写在"非当前显示"的另一块 buffer 里，显示画面完全不受影响，
                //   装载完成后由 write_finish_toggle 那一拍统一切换。
                //   ★ 优先级：手动切图 > 缩放重载 > 自动轮播（2026-10-31 调整）。
                //   缩放是"用户正在主动操作"的事，自动轮播是后台行为，
                //   调缩放时轮播必须让路——否则轮播装载抢占总线，
                //   缩放调节要等轮播间隙，表现就是"时快时慢"。
                //   轮播让路期间 auto_tick 保持为 1，缩放完成/松手后立即补上。
                else if (scan_done && bmp_ready && display_valid && !load_busy
                         && zoom_pending && reload_ok
                         && ((zoom_quiet >= ZOOM_QUIET_GAP)          // ★ 等用户停手 300ms
                             || (zoom_force_cnt >= ZOOM_FORCE_GAP))  // ★ 或连按 400ms 强制刷新
                         && (img_found_count != 3'd0)) begin
                    load_idx         <= img_idx;                  // ★ 还是当前这张
                    load_sector      <= sector_lut(img_idx);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_sec_cnt     <= 16'd0;
                    zoom_pending     <= 1'b0;   // 已按最新比例重载
                    reload_ok        <= 1'b0;   // ★ 节流门闩：400ms 内不许再重载
                    reload_cnt       <= 27'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    auto_sec_cnt     <= 16'd0;
                    zoom_pending     <= 1'b0;   // ★ 这次装载已经用了最新缩放值
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (src_bmp_wr),
    .bmp_data               (src_bmp_data),
    .O_img_w                (src_img_w),
    .O_img_h                (src_img_h),
    .O_frame_start          (src_frame_start)
);

//==========================================================================
//  ★ 自适应缩放器（加分项③）
//    任意尺寸的源图 → 等比缩放到 480 高 → 写进 640x480 帧缓存
//    比 640 窄的居中补黑，比 640 宽的居中裁掉
//==========================================================================
img_scaler u_img_scaler (
    .clk            (clk),
    .rst            (rst),
    .I_wr           (src_bmp_wr),
    .I_data         (src_bmp_data),
    .I_w            (src_img_w),
    .I_h            (src_img_h),
    .I_frame_start  (src_frame_start),
    .I_zoom         (I_zoom_pct),     // ★ 缩放百分比（50~200，100=原图大小）
    .O_wr           (scaled_wr),
    .O_data         (scaled_data),
    .O_done         ()
);

//==========================================================================
//  ★ 原例程在这里例化 sd_card_top（SD 卡控制器）。
//    现在它被提到顶层，因为图片读取（本模块）和音频读取（wav_read）
//    需要共用同一条 SPI 总线，由 sd_bus_arbiter 做扇区级仲裁。
//
//    本模块改为通过端口 sd_sec_read / sd_sec_read_addr /
//    sd_sec_read_data* / sd_sec_read_end 访问 SD 卡，
//    接口时序与原 sd_card_top 完全一致，所以内部逻辑一行没改。
//==========================================================================

//==========================================================================
//  ★ 内部状态引出
//    这些信号原本只在模块内部使用，现在引出来给上层用：
//      O_load_busy       → fade_ctrl（转场模块）据此提前开始淡出
//      O_img_switch      → ★ fade_ctrl 换图才转场（缩放重载不转场，见 fade_ctrl 注释）
//      O_auto_play_en    → OSD 叠加显示自动轮播状态
//      O_img_idx         → OSD 显示 "IMG x/4"
//      O_img_found_count → OSD 显示总数
//==========================================================================
assign O_load_busy       = load_busy;
// ★ "正在装载另一张图" = 装载中且目标图号 ≠ 当前显示图号。
//   换图/轮播/切图：load_idx != img_idx → 1（转场）；
//   缩放重载（还是当前这张）与首图装载：相等 → 0（不转场，直接切换）。
assign O_img_switch      = load_busy && (load_idx != img_idx);
assign O_auto_play_en    = auto_play_en;
assign O_img_idx         = img_idx;
assign O_img_found_count = img_found_count;

endmodule
