//==============================================================================
//  文件名  : key_press_event.v
//  模块名  : key_press_event
//  功能    : 按键事件解析 —— 短按 / 长按 / 双击 / 长按连发
//------------------------------------------------------------------------------
//  【为什么需要这个模块】
//  本作品只有 2 个按键 (key1 / key2)，但要实现的功能有：
//      手动切图、自动轮播开关、轮播周期切换、亮度加减、对比度加减、转场切换
//  一共 6+ 个功能 —— 按键不够用！
//
//  解决办法：【长短按复用】。同一个按键，按一下、按住不放、连按两下，
//  分别代表不同的功能。这就需要先有一个模块把"物理按键的电平"翻译成
//  "人话事件"（短按/长按/双击/连发），本模块就干这件事。
//
//  【输出事件说明】
//      press_pulse   : 短按。★ 注意它是在"双击窗口超时后"才产生的，
//                      所以要等松开后约 DOUBLE_MS 才输出（这是为了区分双击）
//      long_pulse    : 长按（按住超过 LONG_MS）触发一次，松手前不再重复
//      repeat_pulse  : 长按触发后，每 REPEAT_MS 输出一次（用于"按住快速调节"）
//      double_pulse  : 双击（DOUBLE_MS 内按了两次）
//
//  【状态机图解】
//
//                   按下              松开
//      +--------+  ------>  +--------+  ------>  +----------+
//      | K_IDLE |           | K_DOWN |           | K_UPWAIT |
//      +--------+  <------  +--------+  <------  +----------+
//           ^       (长按)      |  |               |      |
//           |                   |  | 按住          |      | 窗口内又按下
//           |                   v  | 到 LONG_MS    |      v
//           |             +--------+               |   +-----------+
//           +--- 松开 ---  | K_LONG |               |   | 双击事件  |
//                         +--------+               |   +-----------+
//                              |                   |        |
//                              | 每 REPEAT_MS      |        v
//                              +-- repeat_pulse    |   (进入 K_LONG，允许"双击后按住")
//                                                  |
//                              窗口超时 --------> press_pulse（确认是短按）
//
//  【消抖】沿用工程里 key_press_debounce 的做法：输入打 2 拍同步 +
//          连续稳定 DEBOUNCE_MS 才认可电平变化（按键机械触点会抖动几毫秒）
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//  说明    : 详细中文注释版，供零基础队员阅读理解
//==============================================================================

module key_press_event #(
    parameter integer CLK_FREQ_HZ = 100_000_000,  // 本模块工作时钟频率
    parameter integer DEBOUNCE_MS = 20,           // 消抖时间（毫秒）
    parameter integer LONG_MS     = 800,          // 按住多久算长按（毫秒）
    parameter integer REPEAT_MS   = 150,          // 长按后连发间隔（毫秒）
    parameter integer DOUBLE_MS   = 300           // 双击判定窗口（毫秒）
)(
    input  wire clk,             // 工作时钟
    input  wire rst,             // 高有效复位

    input  wire button_in,       // 按键输入（板卡上：松开=1，按下=0）

    output reg  press_pulse,     // 短按事件（单拍）
    output reg  long_pulse,      // 长按事件（单拍）
    output reg  repeat_pulse,    // 连发事件（单拍）
    output reg  double_pulse     // 双击事件（单拍）
);

    //--------------------------------------------------------------------------
    // 把"毫秒"换算成"时钟周期数"
    //   例：50MHz、20ms → (50_000_000/1000)*20 = 50_000*20 = 1_000_000 拍
    //--------------------------------------------------------------------------
    localparam integer C_DEB  = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer C_LONG = (CLK_FREQ_HZ / 1000) * LONG_MS;
    localparam integer C_REP  = (CLK_FREQ_HZ / 1000) * REPEAT_MS;
    localparam integer C_DBL  = (CLK_FREQ_HZ / 1000) * DOUBLE_MS;

    //--------------------------------------------------------------------------
    // 状态机编码
    //--------------------------------------------------------------------------
    localparam [1:0] K_IDLE   = 2'd0;   // 空闲（已松开）
    localparam [1:0] K_DOWN   = 2'd1;   // 按下中，正在计时（判断是短按还是长按）
    localparam [1:0] K_LONG   = 2'd2;   // 长按已触发，等待松开或继续连发
    localparam [1:0] K_UPWAIT = 2'd3;   // 已松开，在双击窗口内等待第二次按下

    reg [1:0]  state;
    reg [31:0] cnt;                     // 通用计时器

    //==========================================================================
    //  第 1 部分：按键消抖
    //    button_sync0/1 : 两级同步寄存器，把异步的按键信号同步到本时钟域，
    //                     同时滤掉极短的毛刺
    //    button_stable  : 消抖后的稳定电平（1=松开，0=按下）
    //    deb_cnt        : 电平变化持续计数器，连续稳定够久才更新 button_stable
    //==========================================================================
    reg        button_sync0;
    reg        button_sync1;
    reg        button_stable;
    reg [31:0] deb_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            button_sync0  <= 1'b1;      // 假设复位时按键是松开的
            button_sync1  <= 1'b1;
            button_stable <= 1'b1;
            deb_cnt       <= 32'd0;
        end else begin
            button_sync0 <= button_in;
            button_sync1 <= button_sync0;

            if (button_sync1 == button_stable) begin
                deb_cnt <= 32'd0;                       // 电平没变，计数清零
            end else if (deb_cnt >= C_DEB - 1) begin
                button_stable <= button_sync1;          // 稳定够久，认可新电平
                deb_cnt       <= 32'd0;
            end else begin
                deb_cnt <= deb_cnt + 32'd1;             // 继续观察
            end
        end
    end

    //--------------------------------------------------------------------------
    // 消抖后电平的边沿检测
    //    press_edge  : 按下瞬间（1 → 0）
    //    release_edge: 松开瞬间（0 → 1）
    //--------------------------------------------------------------------------
    reg button_stable_d;
    always @(posedge clk or posedge rst) begin
        if (rst) button_stable_d <= 1'b1;
        else     button_stable_d <= button_stable;
    end

    wire press_edge   = (button_stable_d == 1'b1) && (button_stable == 1'b0);
    wire release_edge = (button_stable_d == 1'b0) && (button_stable == 1'b1);

    //==========================================================================
    //  第 2 部分：事件状态机
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= K_IDLE;
            cnt          <= 32'd0;
            press_pulse  <= 1'b0;
            long_pulse   <= 1'b0;
            repeat_pulse <= 1'b0;
            double_pulse <= 1'b0;
        end else begin
            // 所有事件脉冲默认拉低，只在对应条件成立的当拍拉高（单拍脉冲）
            press_pulse  <= 1'b0;
            long_pulse   <= 1'b0;
            repeat_pulse <= 1'b0;
            double_pulse <= 1'b0;

            case (state)

                //----------------------------------------------------------
                K_IDLE: begin
                    if (press_edge) begin
                        cnt   <= 32'd0;
                        state <= K_DOWN;
                    end
                end

                //----------------------------------------------------------
                // 按下中：要么按够 LONG_MS 变成长按，要么松开立即算短按
                //
                // ★【重要修改 —— 修复"按键被吞"的 bug】
                //   原设计：松开后先进 K_UPWAIT 等 150ms，看用户会不会再按一下
                //           （用来判断双击）。若窗口内又按了 → 判为双击。
                //   问题  ：本工程已改用拨码开关控制模式，不再需要双击，
                //           而 double_pulse 没有接任何功能 —— 结果就是
                //           "快速连按时，第二下被当成双击后丢弃，按了没反应"。
                //   现在  ：松开立即产生短按事件。带来两个好处：
                //           ① 按键响应无延迟（原来要等 150ms 才动作）
                //           ② 快速连按不会被吞，切图手感顺畅
                K_DOWN: begin
                    if (release_edge) begin
                        press_pulse <= 1'b1;        // ★ 立即产生短按事件
                        cnt         <= 32'd0;
                        state       <= K_IDLE;
                    end else if (cnt >= C_LONG - 1) begin
                        long_pulse <= 1'b1;         // 按够时间 → 长按事件
                        cnt        <= 32'd0;
                        state      <= K_LONG;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                //----------------------------------------------------------
                // 长按中：等松开，或者继续连发
                K_LONG: begin
                    if (release_edge) begin
                        state <= K_IDLE;            // ★ 长按后松开不再补发短按
                        cnt   <= 32'd0;
                    end else if (cnt >= C_REP - 1) begin
                        repeat_pulse <= 1'b1;       // 连发事件
                        cnt          <= 32'd0;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                //----------------------------------------------------------
                // 双击窗口：★ 本工程已不再使用（详见上面 K_DOWN 的说明）
                //   保留这段代码仅作参考；现在它永远不会被进入，
                //   所以 double_pulse 也不会产生。
                K_UPWAIT: begin
                    if (press_edge) begin
                        double_pulse <= 1'b1;       // 双击事件
                        cnt          <= 32'd0;
                        state        <= K_LONG;     // 允许"双击后继续按住"变长按
                    end else if (cnt >= C_DBL - 1) begin
                        press_pulse <= 1'b1;        // 窗口超时 → 确认是短按
                        state       <= K_IDLE;
                        cnt         <= 32'd0;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end

                //----------------------------------------------------------
                default: state <= K_IDLE;
            endcase
        end
    end

endmodule
