
//==============================================================================
//  文件名  : video_rgb_to_axis_640x480.v
//  模块名  : video_rgb_to_axis_640x480
//  功能    : RGB + DE/VS 时序 -> AXIS 视频流（对接 TD HDMI 核）
//  时钟域  : video_clk（25MHz）
//  说明    : 参考例程模块
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================

module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= 1'b0;
        O_video_data  <= I_rgb;

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                S_x_cnt <= 11'd0;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // 640x480 最后一个有效像素
            if (S_x_cnt == 11'd639)
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule
