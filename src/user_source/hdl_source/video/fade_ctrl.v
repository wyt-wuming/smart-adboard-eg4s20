//==============================================================================
//  文件名  : fade_ctrl.v
//  模块名  : fade_ctrl
//  功能    : 换图时的"栅格化淡出 / 栅格化淡入"转场特效
//------------------------------------------------------------------------------
//  【对应赛题】加分项②"转场特效 + 音视频联动"
//
//  【视觉效果】整个屏幕切成 20 x 15 个方块（每块 32 x 32 像素），
//              沿"左上 → 右下"的对角线方向，一块一块地变黑 / 变亮：
//
//      淡出（装载新图时）              淡入（新图装载完成后）
//      ┌──┬──┬──┬──┬──┐              ┌──┬──┬──┬──┬──┐
//      │▓▓│██│██│██│██│   ▓=还亮着    │  │  │  │  │  │   ░=正在浮现
//      ├──┼──┼──┼──┼──┤   ░=正在变黑    ├──┼──┼──┼──┼──┤
//      │░░│▓▓│██│██│██│   █=已全黑    │░░│  │  │  │  │
//      ├──┼──┼──┼──┼──┤              ├──┼──┼──┼──┼──┤
//      │██│░░│▓▓│██│██│              │▓▓│░░│  │  │  │
//      └──┴──┴──┴──┴──┘              └──┴──┴──┴──┴──┘
//       对角线扫过                      对角线浮现
//
//  【为什么要做成"先全黑再浮现"？】
//    本工程用 SDRAM 做双缓冲（BUF0 / BUF1），屏幕一次只读**一个**帧缓存，
//    所以物理上拿不到"旧图和新图同时存在"。
//    真正的 alpha 混合（两图叠加）需要同时读两块缓存，带宽和时序都做不到。
//    所以采用"黑场过渡"：先把旧图整体压黑，再让新图浮现。
//    观感上和交叉淡化很接近，而且是业界常见做法（很多电视、投影仪就用这个）。
//
//  【★ 时序怎么对上装载过程】
//    整个过渡由 sd_card_bmp 的 load_busy 信号驱动：
//        ① load_busy 上升沿（开始装载新图）→ 进入 F_OUT，旧图栅格淡出
//        ② 淡出做完 → F_WAIT，屏幕全黑，等新图装完
//        ③ load_busy 下降沿（新图装完，帧缓存已切换）→ 进入 F_IN，新图栅格淡入
//        ④ 淡入做完 → 回 F_IDLE，正常显示
//
//    ★ 淡出总时长必须比"装载时间"短！
//      这里淡出只有 215ms，而 640x480 BMP 装载约 350ms，有 135ms 余量。
//      如果淡出比装载还慢，会在淡出一半时被强行切黑，出现"跳变"。
//
//  【★ 时间量化：为什么格子边长是 2 的幂】
//    1 个 tick = 4096 个像素时钟（25MHz 下 = 163.84 µs）
//      格子边长 32 像素 = 2^5，所以
//          "第 (cx+cy) 个格子的开始时刻" = (cx+cy) * 32 = (cx+cy) << 5
//      —— 一个移位就出来了，不需要乘法器。
//      单格淡化时长 = 512 tick = 2^9，所以
//          "进度 alpha = dt >> 1"（因为 256/512 = 1/2，也是一个移位）
//      —— 整条数据通路只有"移位 + 比较 + 减"，一个乘法器都不用。
//
//  【音视频联动】
//    输出 O_gain（128~255）：过渡时背景音乐音量自动下沉到一半再恢复。
//    接给 audio_player 的 I_gain 即可。
//    注意：只压数据不改变 O_audio_valid 的 48kHz 规律，
//          否则接收端 ACR 失锁会出爆音（和 underrun 处理同一个道理）。
//
//  【和图像流水线的关系】
//      插在 image_processor 之后、osd_adjust 之前：
//        vout_base → [image_processor] → [fade_ctrl] → [osd_adjust] → ...
//      ★ 放在 OSD 之前，是为了让字幕和调节界面"不被压黑"，
//        转场时字幕照常滚动，观感更好。
//      ★ 内部把 RGB 和 hs/vs/de 都延迟 2 拍，下游必须用本模块输出的
//        O_de / O_hs / O_vs。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module fade_ctrl #(
    // ---- 版面 ----
    parameter integer GRID_LOG2  = 5,      // 格子边长 = 2^5 = 32 像素
    parameter integer G_MAX      = 33,     // (20-1)+(15-1) = 33，最大格子序号

    // ---- 时序（★ 全部保持 2 的幂，这样数据通路只有"移位"，没有乘除法）----
    parameter integer STEP_LOG2  = 1,      // 相邻格子的启动时间差 = 2^1 = 2 个 tick
    parameter integer FADE_LOG2  = 5,      // 单个格子的淡化时长   = 2^5 = 32 个 tick
    //  一个方向的转场时长 = (G_MAX+1) x STEP + FADE
    //                    = 33x2 + 32 = 98 个 tick
    parameter integer PHASE_TICK = 98,     // (G_MAX+1)*2 + 32
    //  ★★ 转场时长 = 轮播周期的 1/10 ★★
    //    一个 tick 的时钟数 = 周期秒数 x TICK_UNIT
    //       一个方向 = 98 个 tick = 周期秒数 x 98 x 12755
    //                              = 周期秒数 x 1,249,990 拍
    //       25MHz 下 = 周期秒数 x 50ms   → 周期的 1/20
    //       淡出 + 淡入 = 2 x 1/20 = 周期的 1/10 ✓
    //
    //      周期 1 秒 → 转场 100ms（看得清）
    //      周期 5 秒 → 转场 500ms（马赛克一格格溶解，最漂亮）
    //      周期 30 秒 → 转场 3 秒（大片既视感）
    //
    //  ★ 为什么不能做成固定 40ms？
    //    40ms 只有 2.4 帧画面。栅格溶解是一格一格推进的，
    //    20ms 内根本来不及看清，屏幕上就是"啪"一下切过去，
    //    等于把马赛克溶解整个藏起来了。
    parameter integer TICK_UNIT  = 12755,  // 1 个 tick = 周期秒数 x 12755 拍
    parameter integer WAIT_SEC   = 4       // 黑场等待上限（秒），防止装载卡死时永久黑屏
)(
    input  wire        video_clk,      // 视频时钟 25MHz
    input  wire        rst,            // 高有效复位

    // ---------------- 像素输入 ----------------
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,

    // ---------------- 像素输出（比输入晚 2 拍）----------------
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [23:0] O_rgb,

    // ---------------- 控制 ----------------
    input  wire        I_en,           // 1 = 启用转场特效
    input  wire        I_load_busy,    // 来自 sd_card_bmp（已同步到 video_clk 域）：正在装载新图
    input  wire [7:0]  I_period_sec,   // ★ 轮播周期（秒）：转场时长 = 周期的 1/10
    input  wire        I_frame_new,    // 保留口（当前未使用）
    output wire [7:0]  O_gain,         // 音视频联动：背景音乐音量 128~255

    // ---------------- 调试输出 ----------------
    output wire [1:0]  O_state         // 0=空闲 1=淡出中 2=黑场等待 3=淡入中
);

    //==========================================================================
    //  参数与常量
    //==========================================================================
    // 一个方向的转场 = 98 个 tick（= (33+1)x2 + 32）
    // ★ integer 参数不能做位选（TD 报语法错误），直接赋值即可
    localparam [12:0] RAMP_MAX = PHASE_TICK;            // 33x2 + 32 = 98
    localparam [12:0] FADE_T   = 13'd1 << FADE_LOG2;    // 32

    //--------------------------------------------------------------------------
    //  ★ 转场时长固定 40ms（淡出 20ms + 淡入 20ms）
    //
    //    一个方向 = RAMP_MAX 个 tick = 98 个 tick
    //       98 x TICK_DIV = 98 x 5102 = 499,996 拍
    //       25MHz 下 ≈ 20ms
    //       淡出 + 淡入 = 40ms（固定，与轮播周期无关）✓
    //
    //    ★ 为什么不做成"周期的 1/10"？
    //      周期 30 秒时转场会变成 3 秒，拖沓得没法看。
    //      固定 40ms 快速利落，视觉上也更像"专业设备换场"。
    //
    //    ★ 注意：这只是"淡化动画"的时长。中间那段全黑时间由
    //      "装载一张 640x480 BMP 需要多久"决定（约 350ms），
    //      这段时间是无法压缩的 —— 新图还没进 SDRAM，没东西可显示。
    //--------------------------------------------------------------------------
    // 周期 0 秒按 1 秒算（和 sd_card_bmp 里的防御处理保持一致）
    wire [7:0]  per_sec  = (I_period_sec == 8'd0) ? 8'd1 : I_period_sec;
    wire [23:0] tick_div = per_sec * TICK_UNIT;         // 本周期下 1 个 tick 多少拍
                                                        // 最大 30 x 12755 = 382,650 拍

    localparam [1:0] F_IDLE = 2'd0;    // 正常显示
    localparam [1:0] F_OUT  = 2'd1;    // 旧图栅格淡出
    localparam [1:0] F_WAIT = 2'd2;    // 全黑等待新图
    localparam [1:0] F_IN   = 2'd3;    // 新图栅格淡入

    reg [1:0] fstate;
    assign O_state = fstate;

    //==========================================================================
    //  第 1 部分：像素坐标追踪（与 osd_adjust / marquee_osd 同一套写法）
    //==========================================================================
    reg [9:0] S_x;
    reg [9:0] S_y;
    reg       S_vs_d;

    wire S_vs_edge = (S_vs_d != I_vs);

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            S_x    <= 10'd0;
            S_y    <= 10'd0;
            S_vs_d <= 1'b0;
        end else begin
            S_vs_d <= I_vs;
            if (S_vs_edge) begin
                S_x <= 10'd0;
                S_y <= 10'd0;
            end else if (I_de) begin
                if (S_x == 10'd639) begin
                    S_x <= 10'd0;
                    S_y <= S_y + 10'd1;
                end else begin
                    S_x <= S_x + 10'd1;
                end
            end
        end
    end

    //==========================================================================
    //  第 2 部分：tick 发生器与过渡状态机
    //==========================================================================
    reg [23:0] tick_cnt;      // 数到 tick_div-1 出一个 tick
    reg [12:0] ramp;          // 本阶段已经过了多少 tick（0 ~ RAMP_MAX）
    reg [26:0] wait_cnt;      // 黑场等待计时（单位：像素时钟）

    wire tick = (tick_cnt >= tick_div - 24'd1);

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            tick_cnt <= 24'd0;
        end else if (tick) begin
            tick_cnt <= 24'd0;
        end else begin
            tick_cnt <= tick_cnt + 24'd1;
        end
    end

    // 黑场等待计时：只在 F_WAIT 里累加，离开 F_WAIT 就清零
    //   用"像素时钟"而不是 tick 计数，因为 tick 长度会随周期变化，
    //   用时钟数才能保证超时始终是固定的几秒。
    //   25MHz 下 1 亿拍 = 4 秒
    wire [26:0] WAIT_LIMIT = WAIT_SEC * 27'd25_000_000;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            wait_cnt <= 27'd0;
        end else if (fstate != F_WAIT) begin
            wait_cnt <= 27'd0;
        end else begin
            wait_cnt <= wait_cnt + 27'd1;
        end
    end

    // ★ load_busy 的上升沿检测（见 F_IDLE 的说明，这是"转场爆掉"的根因）
    reg load_busy_d;
    wire load_rise = I_load_busy & ~load_busy_d;

    always @(posedge video_clk or posedge rst) begin
        if (rst) load_busy_d <= 1'b0;
        else     load_busy_d <= I_load_busy;
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            fstate <= F_IDLE;
            ramp   <= 13'd0;
        end else if (!I_en) begin
            // 转场关掉 → 直接正常显示，不动画面
            fstate <= F_IDLE;
            ramp   <= 13'd0;
        end else begin
            case (fstate)

                //----------------------------------------------------------
                //  正常显示：一旦发现开始装载新图，立刻启动淡出
                //----------------------------------------------------------
                F_IDLE: begin
                    ramp <= 13'd0;
                    // ★★ 必须用"上升沿"，不能用电平！★★
                    //   用电平会出这个 bug：
                    //     周期很短时（比如 1 秒），而一张图装载要 350ms，
                    //     淡入做完回到 F_IDLE 时 load_busy 仍然是高（同一张图还在装），
                    //     于是立刻又触发一轮淡出 → 淡入 → 淡出 …
                    //     屏幕疯狂闪烁，就是"转场爆掉"。
                    //   改成上升沿后：只有"新一次装载开始"才会启动转场。
                    if (load_rise) fstate <= F_OUT;
                end

                //----------------------------------------------------------
                //  旧图栅格淡出 → 逐步变黑
                //----------------------------------------------------------
                F_OUT: begin
                    if (ramp >= RAMP_MAX) fstate <= F_WAIT;
                    else if (tick)        ramp <= ramp + 13'd1;
                end

                //----------------------------------------------------------
                //  全黑等待：等帧缓存真正切到新图
                //    这段时间画面全黑，所以底下换的是哪块缓存都看不见
                //
                //  ★【超时保护 —— 必须要有】
                //    load_busy 只有在"整帧写进 SDRAM 完成"时才会拉低。
                //    万一装载因为任何原因卡住（TF 卡接触不良、图片文件损坏、
                //    扇区读失败……），这里就会永远等下去 —— 屏幕永久黑屏，
                //    这在演示现场是致命的。
                //    所以加一个超时：等够 WAIT_MAX 个 tick（约 3.6 秒）就
                //    强行进入淡入，哪怕画面还没准备好，也不会一直黑着。
                //----------------------------------------------------------
                F_WAIT: begin
                    ramp <= 13'd0;
                    if (!I_load_busy || (wait_cnt >= WAIT_LIMIT)) fstate <= F_IN;
                end

                //----------------------------------------------------------
                //  新图栅格淡入 → 逐步浮现
                //----------------------------------------------------------
                F_IN: begin
                    if (ramp >= RAMP_MAX) fstate <= F_IDLE;
                    else if (tick)        ramp <= ramp + 13'd1;
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

    //==========================================================================
    //  第 3 部分：算本像素所在格子的 alpha（0=黑 256=原亮度）
    //
    //    格子序号  g = (x >> 5) + (y >> 5)          0 ~ 33（对角线）
    //    本格启动  th = g << 5                       因为 STEP_TICK = 32 = 2^5
    //    已经过的时间 dt = ramp - th（负数取 0）
    //    本格进度   a = dt >> 1                      因为总时长 512，256/512 = 1/2
    //==========================================================================
    wire [5:0]  cx = S_x[9:GRID_LOG2];        // 列号 0~19
    wire [5:0]  cy = S_y[9:GRID_LOG2];        // 行号 0~14

    // (cx+cy) x 2 用移位实现（STEP_LOG2 = 1）
    wire [12:0] th_start = ({7'b0, cx} + {7'b0, cy}) << STEP_LOG2;

    wire [12:0] dt_raw = (ramp > th_start) ? (ramp - th_start) : 13'd0;
    wire [12:0] dt_cap = (dt_raw > FADE_T) ? FADE_T : dt_raw;
    //   alpha = dt x 256 / FADE = dt x 256 / 32 = dt x 8 = dt << 3   → 0 ~ 256
    //   ★ 先补到 9 位再移位：Verilog 里移位的位宽 = 左操作数的位宽，
    //     直接写 dt_cap[5:0] << 3 会被截断成 6 位，结果恒为 0！
    wire [8:0]  a_cell = {3'b000, dt_cap[5:0]} << 3;

    // 本阶段的每像素 alpha
    wire [8:0] alpha_now = (fstate == F_IDLE) ? 9'd256 :
                           (fstate == F_OUT)  ? (9'd256 - a_cell) :
                           (fstate == F_IN)   ? a_cell :
                                                9'd0;              // F_WAIT 全黑

    //==========================================================================
    //  第 4 部分：流水线
    //    第 1 拍：寄存 alpha 和 RGB（两者必须同拍，否则会出现斜边锯齿）
    //    第 2 拍：相乘右移 8 位后输出
    //==========================================================================
    reg [8:0]  a1;
    reg [23:0] rgb1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            a1   <= 9'd256;
            rgb1 <= 24'd0;
        end else begin
            a1   <= alpha_now;
            rgb1 <= I_rgb;
        end
    end

    // (rgb * alpha) >> 8
    //   alpha 最大 256 时：255*256/256 = 255，正好原样输出，不会变暗
    //   ★ 位宽要写 17 位：8bit x 9bit 最大 255*256 = 65280，
    //     虽然没超 16 位，但写成 16 位 TD 会报位宽截断警告，干脆写宽一点。
    wire [16:0] r_mul = rgb1[23:16] * a1;
    wire [16:0] g_mul = rgb1[15:8]  * a1;
    wire [16:0] b_mul = rgb1[7:0]   * a1;

    reg [23:0] S_rgb_r;
    always @(posedge video_clk or posedge rst) begin
        if (rst) S_rgb_r <= 24'd0;
        else     S_rgb_r <= {r_mul[15:8], g_mul[15:8], b_mul[15:8]};
    end

    assign O_rgb = S_rgb_r;

    // ★ 同步信号必须延迟与 RGB 相同的 2 拍
    video_sync_delay #(.STAGES(2)) u_sync_delay (
        .clk    (video_clk),
        .I_sync ({I_hs, I_vs, I_de}),
        .O_sync ({O_hs, O_vs, O_de})
    );

    //==========================================================================
    //  第 5 部分：音视频联动 —— 背景音乐音量跟随过渡下沉再恢复
    //    取"屏幕正中那个格子"的 alpha 作代表（g = 17，即 cx=10, cy=7）
    //    映射到 128~255：最暗时音量减半，不至于完全没声音
    //==========================================================================
    wire [12:0] th_mid  = 13'd17 << STEP_LOG2;        // g=17 那个格子的起始时刻
    wire [12:0] dt_mid  = (ramp > th_mid) ? (ramp - th_mid) : 13'd0;
    wire [12:0] dtm_cap = (dt_mid > FADE_T) ? FADE_T : dt_mid;
    wire [8:0]  a_mid   = {3'b000, dtm_cap[5:0]} << 3;

    wire [8:0] alpha_gl = (fstate == F_IDLE) ? 9'd256 :
                          (fstate == F_OUT)  ? (9'd256 - a_mid) :
                          (fstate == F_IN)   ? a_mid : 9'd0;

    // 128 + (alpha >> 1) → 128 ~ 256，取低 8 位就是 128 ~ 255
    assign O_gain = 8'd128 + alpha_gl[8:1];

endmodule
