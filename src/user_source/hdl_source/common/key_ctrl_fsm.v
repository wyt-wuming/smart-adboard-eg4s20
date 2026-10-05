//==============================================================================
//  文件名  : key_ctrl_fsm.v   （拨码开关版）
//  模块名  : key_ctrl_fsm
//  功能    : 人机交互控制 —— 4 个拨码开关 + 按键，产生全部系统配置
//------------------------------------------------------------------------------
//  【硬件资源（从 HX4S20C 原理图确认）】
//
//    拨码开关（4 个，网络名 SWKEY_1~4 → FPGA 引脚）：
//        SW1 → C8      SW2 → C7      SW3 → C6      SW4 → C5
//
//    按键（4 个，网络名 KEY_1~4 → FPGA 引脚）：
//        KEY_1 → A2（例程里被当作复位键 rst_n，本设计保持复位功能）
//        KEY_2 → B2（★ 本设计的 key3 —— 专用"减键"，见下面的功能表）
//        KEY_3 → B1（本设计的 key1 —— 与 KEY_4 相邻，操作顺手）
//        KEY_4 → C1（本设计的 key2 —— 专用"加键"）
//
//  【操作方式 —— 请把这张表抄到答辩 PPT 上】
//
//    ┌───────────┬──────────────────────────┬──────────────────────────┐
//    │  拨码开关  │  拨到 ON（本设计约定）    │  拨到 OFF                │
//    ├───────────┼──────────────────────────┼──────────────────────────┤
//    │   SW1     │  调节模式 ADJUST          │  工作模式 RUN            │
//    │   SW2     │  自动轮播（定时切图）      │  固定（停在当前图）      │
//    │   SW3     │  播放音乐                 │  静音                    │
//    │   SW4     │  显示底部字幕传送带        │  隐藏字幕                │
//    └───────────┴──────────────────────────┴──────────────────────────┘
//
//    ┌───────────┬──────────────────────────┬──────────────────────────┐
//    │   按键     │  工作模式（SW1=OFF）      │  调节模式（SW1=ON）      │
//    ├───────────┼──────────────────────────┼──────────────────────────┤
//    │ key1 短按  │  手动切下一张广告图        │  切换要调节的参数项       │
//    │ key1 长按  │  快速连播（按住不停切图）  │  ——（已挪到 key3）        │
//    │ key2 短按  │  轮播周期 +1 秒（5~30）    │  当前参数 +1（可连加）   │
//    │ key2 长按  │  ——（保留）               │  当前参数 +1（可连加）   │
//    │ key3 短按  │  轮播周期 -1 秒（5~30）    │  当前参数 -1（可连减）   │
//    │ key3 长按  │  ——（保留）               │  当前参数 -1（可连减）   │
//    └───────────┴──────────────────────────┴──────────────────────────┘
//
//    key1 = KEY_3(B1)   key2 = KEY_4(C1)   key3 = KEY_2(B2)
//    ★ 本版改动：把 key1 长按的"减"挪到了 key3（KEY_2），
//      现在 key2 专管加、key3 专管减，一加一减对称，不用长按了。
//
//    调节项循环顺序：亮度 BRI → 对比度 CON → 轮播周期 PER → 亮度 …
//
//    参数取值范围：
//        亮度   0 ~ 31（16 = 中性，越小越暗）
//        对比度 0 ~ 31（16 = 中性，越小越灰）
//        轮播周期 5 ~ 30 秒，每一个整数都能取到（默认 5 秒）
//                 到 30 再按 +1 会回到 5；到 5 再按 -1 会回到 30
//
//  【为什么用拨码开关而不是双击】
//    拨码开关是"看得见的状态"，评委一眼就知道当前处于什么模式；
//    而双击需要记忆、还有判定延迟，演示时手感差、易误触。
//
//  【拨码开关极性说明 ★ 重要】
//    原理图上拨码开关一端接 3V3、另一端接 GND，中间通过 120Ω 电阻
//    （RN38）连到 FPGA。所以两个位置分别给出高/低电平。
//    本设计假定"拨到 ON 位置 = 读到高电平"。
//    ★ 如果实际测下来方向相反（拨 ON 反而关闭了功能），
//      只需要把下面参数 SW_ACTIVE_HIGH 改成 1'b0 即可，其它逻辑不用动。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//  说明    : 详细中文注释版，供零基础队员阅读理解
//==============================================================================

module key_ctrl_fsm #(
    parameter integer CLK_FREQ_HZ   = 50_000_000,  // 本模块时钟频率
    parameter [0:0]   SW_ACTIVE_HIGH = 1'b1        // ★ 拨码开关有效电平（1 = ON 时读高）
)(
    input  wire       clk,               // 50MHz 板级时钟
    input  wire       rst,               // 高有效复位

    input  wire       key1,              // 按键 KEY_3（引脚 B1）切图 / 切换调节项
    input  wire       key2,              // 按键 KEY_4（引脚 C1）周期+ / 参数+
    input  wire       key3,              // ★【新增】按键 KEY_2（引脚 B2）周期− / 参数−

    // ---------------- 拨码开关（顶层已同步到本时钟域）----------------
    input  wire       sw_mode,           // SW1(C8): 1=调节模式，0=工作模式
    input  wire       sw_auto,           // SW2(C7): 1=自动轮播，0=固定
    input  wire       sw_music,          // SW3(C6): 1=播放音乐，0=静音
    input  wire       sw_osd,            // SW4(C5): 1=显示OSD，0=隐藏

    // ---------------- 输出配置 ----------------
    // ★ O_period_sec 必须用 wire：它是被下面 assign 连续赋值的。
    //   如果写成 output reg，TD 会报 HDL-8007 语法错误。
    output wire [7:0] O_period_sec,      // 轮播周期（秒），0~30 连续可调
    output reg  [4:0] O_brightness,      // 亮度 0..31（16=中性）
    output reg  [4:0] O_contrast,        // 对比度 0..31（16=中性）
    output reg  [1:0] O_adj_sel,         // 当前调节项 0=亮度 1=对比度 2=周期

    // ---------------- 输出给 sd_card_bmp 的事件 ----------------
    output reg        O_key_next_pulse,  // 手动切下一张（单拍脉冲）

    // ---------------- 派生输出（直接由拨码开关决定）----------------
    output wire       O_adj_mode,        // 1=调节模式
    output wire       O_auto_play,       // 1=自动轮播
    output wire       O_music_en,        // 1=播放音乐
    output wire       O_osd_en           // 1=显示 OSD
);

    //--------------------------------------------------------------------------
    // 拨码开关极性归一化
    //   把"物理电平"统一翻译成"逻辑含义 1=ON"
    //   想反转某个开关的方向，只要改这里的比较即可
    //--------------------------------------------------------------------------
    wire sw_mode_on  = (sw_mode  == SW_ACTIVE_HIGH);
    wire sw_auto_on  = (sw_auto  == SW_ACTIVE_HIGH);
    wire sw_music_on = (sw_music == SW_ACTIVE_HIGH);
    wire sw_osd_on   = (sw_osd   == SW_ACTIVE_HIGH);

    // 4 个开关直接决定 4 个系统状态（组合逻辑，拨动立即生效，无需按键）
    assign O_adj_mode  = sw_mode_on;      // SW1 → 运行/调节模式
    assign O_auto_play = sw_auto_on;      // SW2 → 自动轮播开关
    assign O_music_en  = sw_music_on;     // SW3 → 音乐开关
    assign O_osd_en    = sw_osd_on;       // SW4 → OSD 字幕开关

    //--------------------------------------------------------------------------
    // 参数范围常量
    //--------------------------------------------------------------------------
    localparam [4:0] BRI_MIN = 5'd0,  BRI_MAX = 5'd31, BRI_MID = 5'd16;
    localparam [4:0] CON_MIN = 5'd0,  CON_MAX = 5'd31, CON_MID = 5'd16;

    localparam [1:0] SEL_BRI = 2'd0;
    localparam [1:0] SEL_CON = 2'd1;
    localparam [1:0] SEL_PER = 2'd2;

    //==========================================================================
    //  第 1 部分：例化两个按键事件解析器（消抖 + 短按/长按/连发）
    //    现在不再需要双击了（模式由拨码开关管），所以双击窗口设小一点，
    //    短按响应更快（250ms → 150ms）
    //==========================================================================
    wire k1_press, k1_long, k1_rep, k1_dbl;
    wire k2_press, k2_long, k2_rep, k2_dbl;
    wire k3_press, k3_long, k3_rep, k3_dbl;   // ★ 新增：KEY_2（B2）减键

    key_press_event #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (20),
        .LONG_MS     (800),
        .REPEAT_MS   (150),
        .DOUBLE_MS   (150)
    ) u_key1_event (
        .clk          (clk),
        .rst          (rst),
        .button_in    (key1),
        .press_pulse  (k1_press),
        .long_pulse   (k1_long),
        .repeat_pulse (k1_rep),
        .double_pulse (k1_dbl)
    );

    key_press_event #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (20),
        .LONG_MS     (800),
        .REPEAT_MS   (150),
        .DOUBLE_MS   (150)
    ) u_key2_event (
        .clk          (clk),
        .rst          (rst),
        .button_in    (key2),
        .press_pulse  (k2_press),
        .long_pulse   (k2_long),
        .repeat_pulse (k2_rep),
        .double_pulse (k2_dbl)
    );

    // ---- ★【新增】key3 = KEY_2（B2）：专门当"减键" ----
    key_press_event #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (20),
        .LONG_MS     (800),
        .REPEAT_MS   (150),
        .DOUBLE_MS   (150)
    ) u_key3_event (
        .clk          (clk),
        .rst          (rst),
        .button_in    (key3),
        .press_pulse  (k3_press),
        .long_pulse   (k3_long),
        .repeat_pulse (k3_rep),
        .double_pulse (k3_dbl)
    );

    //==========================================================================
    //  第 2 部分：轮播周期（0 ~ 30 秒，全部整数都能取到，共 31 档）
    //--------------------------------------------------------------------------
    //  ★ 改造说明
    //    以前是 8 个固定档位（2/3/5/8/10/15/20/30 秒），
    //    现在改成 0~30 之间"每一个整数"都能取到，颗粒度 1 秒。
    //
    //  ★ 关于"0 秒"这个特殊值
    //    0 秒在 sd_card_bmp 里被防御性处理成 1 秒（见那里的 period_target），
    //    所以不会出现除零、也不会出现"减 1 下溢"。
    //    实际效果是"每秒换一张图"，正好当作最快轮播来演示。
    //
    //  ★ 只在这一处维护周期常量，避免多个文件各写一份导致不一致
    //==========================================================================
    // ★ 轮播周期范围：5 ~ 30 秒
    //   下限从 0 提到 5 秒，是因为周期太短时：
    //     ① 一张图装载要 350ms，周期 1 秒的话有 1/3 时间在装载
    //     ② 转场还没演完就该换下一张了
    //   5 秒是个舒服的下限。
    localparam [7:0] PER_MIN = 8'd5;      // 最小周期  5 秒
    localparam [7:0] PER_MAX = 8'd30;     // 最大周期 30 秒
    localparam [7:0] PER_DEF = 8'd5;      // 上电默认  5 秒

    reg [7:0] period_val;                 // 当前周期值（秒），范围 0~30

    assign O_period_sec = period_val;

    //==========================================================================
    //  第 3 部分：参数增减任务（用 task 让主逻辑更简洁易懂）
    //==========================================================================
    task adj_up;                              // 当前调节项 +1
        begin
            case (O_adj_sel)
                SEL_BRI: begin
                    if (O_brightness < BRI_MAX) O_brightness <= O_brightness + 5'd1;
                end
                SEL_CON: begin
                    if (O_contrast < CON_MAX) O_contrast <= O_contrast + 5'd1;
                end
                default: begin                    // SEL_PER：周期 +1 秒（到 30 回 0）
                    if (period_val < PER_MAX) period_val <= period_val + 8'd1;
                    else                      period_val <= PER_MIN;
                end
            endcase
        end
    endtask

    task adj_down;                            // 当前调节项 -1
        begin
            case (O_adj_sel)
                SEL_BRI: begin
                    if (O_brightness > BRI_MIN) O_brightness <= O_brightness - 5'd1;
                end
                SEL_CON: begin
                    if (O_contrast > CON_MIN) O_contrast <= O_contrast - 5'd1;
                end
                default: begin                    // SEL_PER：周期 -1 秒（到 0 回 30）
                    if (period_val > PER_MIN) period_val <= period_val - 8'd1;
                    else                      period_val <= PER_MAX;
                end
            endcase
        end
    endtask

    //==========================================================================
    //  第 4 部分：主逻辑
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            period_val       <= PER_DEF;     // 默认 5 秒
            O_brightness     <= BRI_MID;     // 默认中性
            O_contrast       <= CON_MID;     // 默认中性
            O_adj_sel        <= SEL_BRI;     // 默认调节亮度
            O_key_next_pulse <= 1'b0;
        end else begin
            // 事件脉冲默认拉低（只在下面条件成立的当拍拉高）
            O_key_next_pulse <= 1'b0;

            //==================================================================
            //  key1 = KEY_3（B1）
            //    工作模式：短按 = 下一张；长按/连发 = 快速连播
            //    调节模式：短按 = 切换调节项
            //    ★ 原来挂在 key1 长按上的"减"已经挪到 key3（KEY_2 / B2）了
            //==================================================================
            if (O_adj_mode == 1'b0) begin
                // ---- 工作模式 ----
                if (k1_press || k1_rep)
                    O_key_next_pulse <= 1'b1;     // 连发时按住不放 = 快速连播
            end else begin
                // ---- 调节模式 ----
                if (k1_press)
                    O_adj_sel <= (O_adj_sel == SEL_PER) ? SEL_BRI : (O_adj_sel + 2'd1);
            end

            //==================================================================
            //  key2
            //    工作模式：短按 = 轮播周期 +1 档
            //    调节模式：短按/长按连发 = 当前参数 +1
            //==================================================================
            if (O_adj_mode == 1'b0) begin
                // ---- 工作模式：周期 +1 档 ----
                if (k2_press) begin
                    if (period_val < PER_MAX) period_val <= period_val + 8'd1;
                    else                      period_val <= PER_MIN;
                end
            end else begin
                // ---- 调节模式：参数 +1 ----
                if (k2_press || k2_rep)
                    adj_up;
            end

            //==================================================================
            //  key3 = KEY_2（B2）★【新增】专门当"减键"
            //    工作模式：短按 = 轮播周期 -1 秒（对称于 key2 的 +1）
            //    调节模式：短按/长按连发 = 当前参数 -1
            //==================================================================
            if (O_adj_mode == 1'b0) begin
                // ---- 工作模式：周期 -1 秒 ----
                if (k3_press) begin
                    if (period_val > PER_MIN) period_val <= period_val - 8'd1;
                    else                      period_val <= PER_MAX;
                end
            end else begin
                // ---- 调节模式：参数 -1 ----
                if (k3_press || k3_rep)
                    adj_down;
            end

        end
    end

endmodule
