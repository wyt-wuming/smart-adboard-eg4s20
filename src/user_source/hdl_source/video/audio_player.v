//==============================================================================
//  文件名  : audio_player.v
//  模块名  : audio_player
//  功能    : 从音频 FIFO 取 PCM，按 48kHz 节拍送给 HDMI 1.4b 发射核
//  时钟域  : video_clk（25MHz）
//------------------------------------------------------------------------------
//  【它在音频链路里的位置】
//
//    TF卡 → wav_read → 异步FIFO(100MHz写/25MHz读) → 【audio_player】 → HDMI核
//
//  【三个关键技术点，每一处写错都会出问题】
//
//  1) 48kHz 节拍怎么产生
//     本模块工作在 video_clk = 25.000MHz（PLL 精确产生）。
//     25_000_000 / 48_000 = 520.8333...，不是整数，所以不能用固定分频，
//     必须用"分数分频累加器"：每拍累加 48000，累加到 25000000 就输出一拍并减去。
//     长期平均正好是 48.000kHz（误差 < 0.001%）。
//
//  2) O_audio_valid 必须"无条件"保持 48kHz 规律 ★
//     HDMI 接收端靠 ACR 参数恢复音频时钟，而 ACR 是根据 audio_valid 的
//     实际速率测量出来的。如果 FIFO 空了就停止发 valid，接收端会以为
//     采样率变了 → 失锁 → 周期性爆音/静音。
//     所以：即使 FIFO 空了（欠载），也要照常发 valid，只是把数据填 0（静音）。
//
//  3) 16bit 源数据要左移 8 位变成 24bit
//     HDMI 核吃 24bit 有符号 PCM，16bit 数据左移 8 位即可无损扩展
//     （低 8 位补 0），永远不过载。
//
//  【FWFT 说明】
//     本工程用的异步 FIFO 是 "First-Word Fall-Through" 语义：
//     empty_flag==0 时，dout 上已经就是队首数据；
//     把 re 拉高一拍，就弹出它，下一拍 dout 自动变成新的队首。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module audio_player #(
    parameter integer CLK_FREQ_HZ    = 25_000_000,   // video_clk 频率
    parameter integer SAMPLE_RATE_HZ = 48_000        // 音频采样率
)(
    input  wire        video_clk,          // 视频时钟 25MHz
    input  wire        rst,                // 高有效复位

    // ---------------- 音频 FIFO 读侧 ----------------
    input  wire [31:0] I_fifo_dout,        // 队首数据 {R[15:0], L[15:0]}
    input  wire        I_fifo_empty,
    output reg         O_fifo_re,          // 弹出队首（拉高一拍）

    // ---------------- HDMI 发射核音频口（并行 PCM，非 I2S）----------------
    output reg         O_audio_valid,      // 采样有效（1 拍）
    output reg  [23:0] O_audio_left_data,  // 左声道 24bit 有符号
    output reg  [23:0] O_audio_right_data, // 右声道 24bit 有符号

    // ---------------- 音量控制（255 = 原音量）----------------
    input  wire [7:0]  I_gain,

    // ---------------- 调试/自检 ----------------
    output reg  [15:0] O_underrun_cnt,     // 欠载次数（>0 说明供数跟不上）
    output reg  [15:0] O_frame_cnt         // 已播放帧数
);

    //==========================================================================
    //  第 1 部分：48kHz 节拍发生器（分数分频累加器）
    //==========================================================================
    reg  [31:0] S_acc;                                   // 累加器
    wire [32:0] W_acc_add = {1'b0, S_acc} + SAMPLE_RATE_HZ;   // 33 位防溢出
    reg         S_tick;                                  // 48kHz 单拍脉冲

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            S_acc  <= 32'd0;
            S_tick <= 1'b0;
        end else if (W_acc_add >= CLK_FREQ_HZ) begin
            S_acc  <= W_acc_add[31:0] - CLK_FREQ_HZ;     // 减去一整圈
            S_tick <= 1'b1;
        end else begin
            S_acc  <= W_acc_add[31:0];
            S_tick <= 1'b0;
        end
    end

    //==========================================================================
    //  第 2 部分：音量缩放
    //    24bit 有符号 × 8bit 增益 ÷ 256（算术右移 8 位保留符号）
    //    增益 = 255 时直接旁通，做到 1:1 无损
    //==========================================================================
    function signed [23:0] apply_gain;
        input signed [23:0] s;
        input        [7:0]  g;
        reg   signed [31:0] t;
        begin
            if (g == 8'd255)
                apply_gain = s;                 // 原音量，不动
            else begin
                t = s * $signed({1'b0, g});
                apply_gain = t[31:8];           // 算术右移 8 位
            end
        end
    endfunction

    //==========================================================================
    //  第 3 部分：取数并驱动 HDMI 核
    //==========================================================================
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            O_audio_valid      <= 1'b0;
            O_fifo_re          <= 1'b0;
            O_audio_left_data  <= 24'sd0;
            O_audio_right_data <= 24'sd0;
            O_underrun_cnt     <= 16'd0;
            O_frame_cnt        <= 16'd0;
        end else begin
            O_fifo_re     <= 1'b0;      // 默认拉低
            O_audio_valid <= 1'b0;

            if (S_tick) begin
                // ★ 无论 FIFO 有没有数据，valid 都保持 48kHz 规律（见文件头说明 2）
                O_audio_valid <= 1'b1;

                if (!I_fifo_empty) begin
                    // FIFO 有数据：取出队首，按 16→24bit 扩展后送出去
                    O_audio_left_data  <= apply_gain({I_fifo_dout[15:0],  8'h00}, I_gain);
                    O_audio_right_data <= apply_gain({I_fifo_dout[31:16], 8'h00}, I_gain);
                    O_fifo_re          <= 1'b1;      // 下一拍弹出队首
                    O_frame_cnt        <= O_frame_cnt + 16'd1;
                end else begin
                    // FIFO 空了（欠载）：送静音，但 valid 照发
                    O_audio_left_data  <= 24'sd0;
                    O_audio_right_data <= 24'sd0;
                    O_underrun_cnt     <= O_underrun_cnt + 16'd1;
                end
            end
        end
    end

endmodule
