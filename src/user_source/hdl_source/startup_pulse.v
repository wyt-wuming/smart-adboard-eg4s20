
//==============================================================================
//  文件名  : startup_pulse.v
//  模块名  : startup_pulse
//  功能    : 上电后延迟固定拍数输出一个单拍脉冲（触发 EDID 读取）
//  时钟域  : video_clk（25MHz）
//  说明    : 参考例程模块
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================

module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000
)(
    input  wire I_clk,
    input  wire I_rst,
    output reg  O_pulse
);

reg [19:0] S_cnt;
reg        S_done;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;

        if (!S_done) begin
            if (S_cnt == CNT_MAX - 1'b1) begin
                S_cnt   <= S_cnt;
                S_done  <= 1'b1;
                O_pulse <= 1'b1;
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end

endmodule
