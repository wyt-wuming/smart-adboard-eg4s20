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
//        KEY_1 → A2（例程里被当作复位键 rst_n）
//        KEY_2 → B2（例程里叫 key1）
//        KEY_3 → B1（★ 例程完全没用到的空闲按键）
//        KEY_4 → C1（例程里叫 key2）
//
//  【操作方式 —— 请把这张表抄到答辩 PPT 上】
//
//    ┌───────────┬──────────────────────────┬──────────────────────────┐
//    │  拨码开关  │  拨到 ON（本设计约定）    │  拨到 OFF                │
//    ├───────────┼──────────────────────────┼──────────────────────────┤
//    │   SW1     │  调节模式 ADJUST          │  工作模式 RUN            │
//    │   SW2     │  自动轮播（定时切图）      │  固定（停在当前图）      │
//    │   SW3     │  淡入淡出转场             │  硬切（瞬间切换）        │
//    │   SW4     │  显示 OSD 字幕/时间        │  隐藏 OSD                │
//    └───────────┴──────────────────────────┴──────────────────────────┘
//
//    ┌───────────┬──────────────────────────┬──────────────────────────┐
//    │   按键     │  工作模式（SW1=OFF）      │  调节模式（SW1=ON）      │
//    ├───────────┼──────────────────────────┼──────────────────────────┤
//    │ key1 短按  │  手动切下一张广告图        │  切换要调节的参数项       │
//    │ key1 长按  │  快速连播（按住不停切图）  │  当前参数 -1（可连减）   │
//    │ key2 短按  │  轮播周期 +1 档            │  当前参数 +1（可连加）   │
//    │ key2 长按  │  ——（保留）               │  当前参数 +1（可连加）   │
//    └───────────┴──────────────────────────┴──────────────────────────┘
//
//    调节项循环顺序：亮度 BRI → 对比度 CON → 轮播周期 PER → 亮度 …
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

    input  wire       key1,              // 按键 KEY_2（引脚 B2）
    input  wire       key2,              // 按键 KEY_4（引脚 C1）

    // ---------------- 拨码开关（顶层已同步到本时钟域）----------------
    input  wire       sw_mode,           // SW1(C8): 1=调节模式，0=工作模式
    input  wire       sw_auto,           // SW2(C7): 1=自动轮播，0=固定
    input  wire       sw_trans,          // SW3(C6): 1=淡入淡出，0=硬切
    input  wire       sw_osd,            // SW4(C5): 1=显示OSD，0=隐藏

    // ---------------- 输出配置 ----------------
    output reg  [7:0] O_period_sec,      // 轮播周期（秒）
    output reg  [4:0] O_brightness,      // 亮度 0..31（16=中性）
    output reg  [4:0] O_contrast,        // 对比度 0..31（16=中性）
    output reg  [1:0] O_adj_sel,         // 当前调节项 0=亮度 1=对比度 2=周期

    // ---------------- 输出给 sd_card_bmp 的事件 ----------------
    output reg        O_key_next_pulse,  // 手动切下一张（单拍脉冲）

    // ---------------- 派生输出（直接由拨码开关决定）----------------
    output wire       O_adj_mode,        // 1=调节模式
    output wire       O_auto_play,       // 1=自动轮播
    output wire       O_fade_en,         // 1=开启转场
    output wire       O_osd_en           // 1=显示 OSD
);

    //--------------------------------------------------------------------------
    // 拨码开关极性归一化
    //   把"物理电平"统一翻译成"逻辑含义 1=ON"
    //   想反转某个开关的方向，只要改这里的比较即可
    //--------------------------------------------------------------------------
    wire sw_mode_on  = (sw_mode  == SW_ACTIVE_HIGH);
    wire sw_auto_on  = (sw_auto  == SW_ACTIVE_HIGH);
    wire sw_trans_on = (sw_trans == SW_ACTIVE_HIGH);
    wire sw_osd_on   = (sw_osd   == SW_ACTIVE_HIGH);

    // 4 个开关直接决定 4 个系统状态（组合逻辑，拨动立即生效，无需按键）
    assign O_adj_mode  = sw_mode_on;      // SW1 → 运行/调节模式
    assign O_auto_play = sw_auto_on;      // SW2 → 自动轮播开关
    assign O_fade_en   = sw_trans_on;     // SW3 → 转场特效开关
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

    //==========================================================================
    //  第 2 部分：周期档位表（8 档）
    //    ★ 只在这一处维护周期表，避免多个文件各写一份导致不一致
    //==========================================================================
    reg [2:0] period_idx;

    always @(*) begin
        case (period_idx)
            3'd0: O_period_sec = 8'd2;      // 2 秒
            3'd1: O_period_sec = 8'd3;      // 3 秒
            3'd2: O_period_sec = 8'd5;      // 5 秒（默认）
            3'd3: O_period_sec = 8'd8;      // 8 秒
            3'd4: O_period_sec = 8'd10;     // 10 秒
            3'd5: O_period_sec = 8'd15;     // 15 秒
            3'd6: O_period_sec = 8'd20;     // 20 秒
            default: O_period_sec = 8'd30;  // 30 秒
        endcase
    end

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
                default: begin                    // SEL_PER：周期档位循环加
                    if (period_idx < 3'd7) period_idx <= period_idx + 3'd1;
                    else                   period_idx <= 3'd0;
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
                default: begin                    // SEL_PER：周期档位循环减
                    if (period_idx > 3'd0) period_idx <= period_idx - 3'd1;
                    else                   period_idx <= 3'd7;
                end
            endcase
        end
    endtask

    //==========================================================================
    //  第 4 部分：主逻辑
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            period_idx       <= 3'd2;        // 默认 5 秒
            O_brightness     <= BRI_MID;     // 默认中性
            O_contrast       <= CON_MID;     // 默认中性
            O_adj_sel        <= SEL_BRI;     // 默认调节亮度
            O_key_next_pulse <= 1'b0;
        end else begin
            // 事件脉冲默认拉低（只在下面条件成立的当拍拉高）
            O_key_next_pulse <= 1'b0;

            //==================================================================
            //  key1
            //    工作模式：短按 = 下一张；长按/连发 = 快速连播
            //    调节模式：短按 = 切换调节项；长按/连发 = 当前项 -1
            //==================================================================
            if (O_adj_mode == 1'b0) begin
                // ---- 工作模式 ----
                if (k1_press || k1_rep)
                    O_key_next_pulse <= 1'b1;     // 连发时按住不放 = 快速连播
            end else begin
                // ---- 调节模式 ----
                if (k1_press)
                    O_adj_sel <= (O_adj_sel == SEL_PER) ? SEL_BRI : (O_adj_sel + 2'd1);
                if (k1_rep)
                    adj_down;                     // 长按连续减
            end

            //==================================================================
            //  key2
            //    工作模式：短按 = 轮播周期 +1 档
            //    调节模式：短按/长按连发 = 当前参数 +1
            //==================================================================
            if (O_adj_mode == 1'b0) begin
                // ---- 工作模式：周期 +1 档 ----
                if (k2_press) begin
                    if (period_idx < 3'd7) period_idx <= period_idx + 3'd1;
                    else                   period_idx <= 3'd0;
                end
            end else begin
                // ---- 调节模式：参数 +1 ----
                if (k2_press || k2_rep)
                    adj_up;
            end

        end
    end

endmodule
