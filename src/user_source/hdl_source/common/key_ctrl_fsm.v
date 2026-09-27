//==============================================================================
//  文件名  : key_ctrl_fsm.v
//  模块名  : key_ctrl_fsm
//  功能    : 2 个按键的功能复用状态机 —— 把长短按/双击翻译成系统配置
//------------------------------------------------------------------------------
//  【设计背景：2 个按键要管 6 件事】
//  板卡上可用的只有 key1(B2) 和 key2(C1)，但作品需要这些操作：
//      ① 手动切下一张广告图      ② 自动轮播 开/关
//      ③ 轮播周期切换            ④ 亮度 +/-
//      ⑤ 对比度 +/-              ⑥ 转场特效开关
//
//  解决办法：分"运行模式(RUN)"和"调节模式(ADJUST)"两种状态，用长短按区分。
//
//  【按键映射表 —— 请把这张表抄到答辩 PPT 上】
//
//   操作             key1 (B2)                      key2 (C1)
//   --------------------------------------------------------------------------
//   短按       RUN: 下一张                    RUN: 自动轮播 开/关
//              ADJ: 当前参数 -1               ADJ: 当前参数 +1
//   --------------------------------------------------------------------------
//   双击       RUN/ADJ: 进出 ADJUST 模式      周期 +1 档（2→3→5→8→10→15→20→30→2 秒）
//   --------------------------------------------------------------------------
//   长按       RUN: 快速连播（按住不停切图）   RUN: 转场模式循环 关→淡入淡出→擦除→关
//   (≥0.8s)    ADJ: 参数快速 -1               ADJ: 切换当前调节项（亮度→对比度→周期）
//
//  【为什么"双击 key2 改周期"要单独留一个手势】
//  轮播周期是赛题明确要求的"可配置"功能，演示时一定会展示，
//  所以必须做到"不用进入任何模式，随手两下就能改"。
//
//  【时钟域】
//  本模块工作在 50MHz 的板级时钟 clk 域。
//  输出的配置参数要跨到 sd_card_clk(100MHz) 和 video_clk(25MHz)，
//  由 cfg_cdc 模块完成（见 common/cfg_cdc.v）。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//  说明    : 详细中文注释版，供零基础队员阅读理解
//==============================================================================

module key_ctrl_fsm #(
    parameter integer CLK_FREQ_HZ = 50_000_000   // 本模块时钟频率
)(
    input  wire       clk,               // 50MHz 板级时钟
    input  wire       rst,               // 高有效复位

    input  wire       key1,              // 按键 1（引脚 B2）
    input  wire       key2,              // 按键 2（引脚 C1）

    // ---------------- 输出给各子系统的配置 ----------------
    output reg  [7:0] O_period_sec,      // 轮播周期（单位：秒，取值 2/3/5/8/10/15/20/30）
    output reg  [4:0] O_brightness,      // 亮度 0..31（16 = 中性）
    output reg  [4:0] O_contrast,        // 对比度 0..31（16 = 中性）
    output reg  [1:0] O_trans_mode,      // 转场模式 0=关闭 1=淡入淡出 2=擦除
    output reg  [1:0] O_adj_sel,         // ADJUST 模式下当前调节项 0=亮度 1=对比度 2=周期
    output reg        O_adj_mode,        // 模式指示 0=RUN(运行) 1=ADJUST(调节)

    // ---------------- 输出给 sd_card_bmp 的事件脉冲 ----------------
    output reg        O_key_next_pulse,  // 手动切下一张（单拍脉冲）
    output reg        O_key_auto_pulse,  // 自动轮播开关翻转（单拍脉冲）

    // ---------------- 派生输出 ----------------
    output wire       O_fade_en          // 转场使能（由 O_trans_mode 派生）
);

    //--------------------------------------------------------------------------
    // 参数范围常量
    //--------------------------------------------------------------------------
    localparam [4:0] BRI_MIN = 5'd0,  BRI_MAX = 5'd31, BRI_MID = 5'd16;
    localparam [4:0] CON_MIN = 5'd0,  CON_MAX = 5'd31, CON_MID = 5'd16;

    // 模式编码
    localparam M_RUN    = 1'b0;
    localparam M_ADJUST = 1'b1;

    // 调节项编码
    localparam [1:0] SEL_BRI = 2'd0;
    localparam [1:0] SEL_CON = 2'd1;
    localparam [1:0] SEL_PER = 2'd2;

    // 转场模式编码
    localparam [1:0] TR_OFF  = 2'd0;     // 关闭（硬切）
    localparam [1:0] TR_FADE = 2'd1;     // 淡出→黑→淡入
    localparam [1:0] TR_WIPE = 2'd2;     // 黑幕擦除

    //==========================================================================
    //  第 1 部分：例化两个按键事件解析器
    //==========================================================================
    wire k1_press, k1_long, k1_rep, k1_dbl;
    wire k2_press, k2_long, k2_rep, k2_dbl;

    key_press_event #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (20),
        .LONG_MS     (800),
        .REPEAT_MS   (150),
        .DOUBLE_MS   (250)
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
        .DOUBLE_MS   (250)
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
    //  第 2 部分：周期档位表
    //    内部用 period_idx(0..7) 作索引，对外输出 O_period_sec（秒）
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
    //  第 3 部分：主状态机
    //    说明：所有输出都是寄存器，每个事件脉冲只持续 1 拍
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            O_adj_mode       <= M_RUN;
            period_idx       <= 3'd2;        // 默认 5 秒
            O_brightness     <= BRI_MID;     // 默认中性
            O_contrast       <= CON_MID;     // 默认中性
            O_trans_mode     <= TR_FADE;     // 默认开启淡入淡出
            O_adj_sel        <= SEL_BRI;
            O_key_next_pulse <= 1'b0;
            O_key_auto_pulse <= 1'b0;
        end else begin
            // 事件脉冲默认拉低（只在下面条件成立的当拍拉高）
            O_key_next_pulse <= 1'b0;
            O_key_auto_pulse <= 1'b0;

            //==================================================================
            //  key1 处理
            //==================================================================
            if (k1_press || k1_rep) begin
                if (O_adj_mode == M_RUN) begin
                    // ---- 运行模式：短按/连发 都是"切下一张" ----
                    //      连发时按住不放就能"快速连播"
                    O_key_next_pulse <= 1'b1;
                end else begin
                    // ---- 调节模式：当前参数 -1 ----
                    case (O_adj_sel)
                        SEL_BRI: begin
                            if (O_brightness > BRI_MIN)
                                O_brightness <= O_brightness - 5'd1;
                        end
                        SEL_CON: begin
                            if (O_contrast > CON_MIN)
                                O_contrast <= O_contrast - 5'd1;
                        end
                        default: begin          // SEL_PER：周期档位循环减
                            if (period_idx > 3'd0)
                                period_idx <= period_idx - 3'd1;
                            else
                                period_idx <= 3'd7;   // 到头回到最大档
                        end
                    endcase
                end
            end

            // key1 双击：进出 ADJUST 调节模式
            if (k1_dbl) begin
                O_adj_mode <= ~O_adj_mode;
                O_adj_sel  <= SEL_BRI;       // 每次进入都从"亮度"开始，方便记忆
            end

            //==================================================================
            //  key2 处理
            //==================================================================
            if (k2_press || (k2_rep && (O_adj_mode == M_ADJUST))) begin
                if (O_adj_mode == M_RUN) begin
                    // ---- 运行模式：短按 = 自动轮播开/关 ----
                    //      （注意：连发在运行模式下不响应，避免误触）
                    if (k2_press)
                        O_key_auto_pulse <= 1'b1;
                end else begin
                    // ---- 调节模式:当前参数 +1 ----
                    case (O_adj_sel)
                        SEL_BRI: if (O_brightness < BRI_MAX)
                                     O_brightness <= O_brightness + 5'd1;
                        SEL_CON: if (O_contrast < CON_MAX)
                                     O_contrast <= O_contrast + 5'd1;
                        default: if (period_idx < 3'd7)
                                     period_idx <= period_idx + 3'd1;
                                     else
                                     period_idx <= 3'd0;
                    endcase
                end
            end

            // key2 双击：轮播周期 +1 档
            //   ★ 这个手势在 RUN / ADJUST 两种模式下都有效，
            //     因为"周期可配置"是赛题硬性要求，演示时要能随手改
            if (k2_dbl) begin
                if (period_idx < 3'd7)
                    period_idx <= period_idx + 3'd1;
                else
                    period_idx <= 3'd0;
            end

            // key2 长按
            if (k2_long) begin
                if (O_adj_mode == M_RUN) begin
                    // ---- 运行模式：转场模式循环 关→淡入淡出→擦除→关 ----
                    if (O_trans_mode == TR_WIPE)
                        O_trans_mode <= TR_OFF;
                    else
                        O_trans_mode <= O_trans_mode + 2'd1;
                end else begin
                    // ---- 调节模式：切换当前调节项 ----
                    if (O_adj_sel == SEL_PER)
                        O_adj_sel <= SEL_BRI;
                    else
                        O_adj_sel <= O_adj_sel + 2'd1;
                end
            end

        end
    end

    //==========================================================================
    //  派生信号：转场使能（只要不是 TR_OFF 就使能）
    //==========================================================================
    assign O_fade_en = (O_trans_mode != TR_OFF);

endmodule
