
//==============================================================================
//  文件名  : sd_card_bmp.v   （改造版）
//  功能    : TF 卡 BMP 图片扫描 / 装载 / 轮播调度 / 双缓冲切换
//------------------------------------------------------------------------------
//  【本次改造（赛题一）新增/修改的内容，用 ★ 标出】
//    ★1. 新增 I_period_sec 端口：轮播周期由外部按键状态机给出（赛题要求"周期可配置"）
//        原来写死 1 秒（assign auto_tick = (auto_cnt == CLK_FREQ_HZ - 1)），
//        现在改成"1 秒节拍 + 秒计数器"，与 I_period_sec 比较。
//        这样做同时避免了一个坑：若继续用"周期×100MHz"直接比较，
//        30 秒 × 100MHz = 3.0e9 会超出 32 位有符号整数范围（2.147e9）导致溢出。
//    ★2. 删除了内部两个 key_press_debounce 例化：
//        外层 key_ctrl_fsm 已经完成了消抖，送进来的是"单拍脉冲"。
//        若在这里再消抖一次，20ns 宽的脉冲会被漏掉 → 按键完全失效！
//    ★3. 新增若干"状态输出"端口（O_load_busy / O_auto_play_en /
//        O_img_idx / O_img_found_count），供 OSD 叠加和转场控制使用。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统
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
    input                       auto_play_ext,    // ★【改】自动轮播开关（电平），来自拨码开关 SW2
    input  [7:0]                I_period_sec,     // ★【新增】轮播周期（秒），来自 key_ctrl_fsm
    output [3:0]                state_code,       // bmp_read 状态码（送数码管）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,    // 是否已有可显示的画面

    // ---- ★【新增】给 OSD / 转场模块用的状态输出 ----
    output                      O_load_busy,      // 正在装载新图（转场淡出用）
    output                      O_auto_play_en,   // 自动轮播是否开启（OSD 显示用）
    output [1:0]                O_img_idx,        // 当前显示第几张（OSD 显示用）
    output [2:0]                O_img_found_count,// 共找到几张图（OSD 显示用）

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
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
// ★【改造】自动轮播开关改成"外部电平"：由拨码开关 SW2 直接控制，
//   不再是内部按键翻转，所以用 wire 而不是 reg
wire             auto_play_en = auto_play_ext;
// ★【改造】轮播周期计数：改成"1 秒节拍 + 秒计数器"
//   原实现是 reg [31:0] auto_cnt + 与 CLK_FREQ_HZ-1 比较（写死 1 秒）。
//   改成秒计数器后：① 周期可通过 I_period_sec 配置 ② 最长 30 秒也不会溢出
reg [26:0]       sec_div_cnt;      // 1 秒分频计数器（100MHz 时钟下数到 99_999_999）
reg              tick_1sec;        // 1 秒单拍脉冲
reg [15:0]       auto_sec_cnt;     // 自动轮播已累计的秒数
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
//--------------------------------------------------------------------------
// ★【改造】自动轮播计时：1 秒节拍 + 秒计数
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
// ★【改造】原例程在这里例化两个 key_press_debounce 做按键消抖。
//   现在按键消抖与长短按/双击解析已由外层的 key_ctrl_fsm + key_press_event
//   完成，送进来的是"单拍脉冲"（宽度 1 个时钟周期），必须直接使用。
//
//   ★ 若在这里再消抖一次：20ns 宽的脉冲会被 2 级同步器采样到，
//     但消抖计数器要求电平"连续稳定 20ms"，单拍脉冲根本达不到，
//     结果是 press_pulse 永远不产生 —— 按键完全失效！
//     这是本次改造中最隐蔽、最容易踩的坑，务必保留此注释。
//--------------------------------------------------------------------------
//--------------------------------------------------------------------------
// ★【修复】按键脉冲跨时钟域同步
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

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
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
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_sec_cnt          <= 16'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

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
                // ★【改】自动轮播现在完全由拨码开关 SW2 控制（外部电平），
                //   所以这里不再自动开启，也不需要按键翻转逻辑。
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_sec_cnt          <= 16'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
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

                // ★【改】自动轮播开关现在由拨码开关 SW2 直接控制（电平信号），
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
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_sec_cnt     <= 16'd0;
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
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

//==========================================================================
//  ★【新增】内部状态引出
//    这些信号原本只在模块内部使用，现在引出来给上层用：
//      O_load_busy       → fade_ctrl（转场模块）据此提前开始淡出
//      O_auto_play_en    → OSD 叠加显示自动轮播状态
//      O_img_idx         → OSD 显示 "IMG x/4"
//      O_img_found_count → OSD 显示总数
//==========================================================================
assign O_load_busy       = load_busy;
assign O_auto_play_en    = auto_play_en;
assign O_img_idx         = img_idx;
assign O_img_found_count = img_found_count;

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
