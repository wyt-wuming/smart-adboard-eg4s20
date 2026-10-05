//==============================================================================
//  文件名  : marquee_osd.v
//  模块名  : marquee_osd
//  功能    : 屏幕底部"新闻联播式"传送带字幕 —— 白字 + 半透明深色底条，从右往左滚
//------------------------------------------------------------------------------
//  【对应赛题】加分项①"OSD 字幕叠加"
//
//  【显示效果】
//
//      ┌────────────────────────────────────────────┐
//      │                                            │
//      │            广告画面 640x480                 │
//      │                                            │
//      ├────────────────────────────────────────────┤ ← y=440 底条上沿
//      │▓▓ 安路科技 智能数字广告牌 欢迎光临 ▓▓▓▓▓▓▓▓▓│ ← 白字，16px 高
//      └────────────────────────────────────────────┘ ← y=479
//         文字从右向左滚动 50 像素/秒
//         滚完一轮 → 停 2 秒 → 再来一轮（循环）
//
//  【版面参数】
//      底条   : y = 440 ~ 479（40 像素高，整宽 640）
//              底条用"原画面右移 1 位"实现半透明压暗，不做调色板
//      文字行 : y = 452 ~ 467（16 像素高，垂直居中）
//      滚动   : 50 像素/秒（可改 SPEED_PPS 参数）
//
//  【滚动算法】（★ 用无符号运算，不要引入负数）
//      设 scroll_pos = 已经滚过去的像素数（0 起步）
//      则第 0 个字的左边缘在屏幕 x = 640 - scroll_pos
//      对屏幕上某个像素 x，它在文本里的相对位置：
//              rel = x + scroll_pos - 640
//      因为是无符号数，判断"rel >= 0"就变成判断"x + scroll_pos >= 640"
//      然后：
//              第几个字 = rel >> 4
//              字内第几列 = rel & 15
//
//      一轮总滚动距离 = 640（屏幕宽） + 文字总宽
//      滚到总距离后停 PAUSE_MS 毫秒，再从头开始。
//
//  【跨时钟域接收】
//      txt_read 在 100MHz 域，本模块在 25MHz 域。用翻转握手：
//        对端翻转 I_req_tgl → 本模块两级同步后发现变化 → 取走索引
//                                → 翻转 O_ack_tgl 通知对端可以送下一个
//      索引在"请求翻转 → 收到应答"期间保持不变，所以跨域安全。
//
//  【和图像流水线的关系】
//      本模块插在 osd_adjust 之后、转 RGB/AXIS 之前：
//        vout_base → [image_processor] → [osd_adjust] → [marquee_osd] → axis
//      ★ 内部把 RGB 和 hs/vs/de 都延迟 4 拍（见下面的流水线说明），
//        所以下游必须用本模块输出的 O_de/O_hs/O_vs。
//
//  【★ 三级流水线对齐】（改代码前务必看懂）
//      第 0 拍 : 从 S_x/S_y 算出 是否在底条内 / 第几个字 / 字内第几列 / 行号
//      第 1 拍 : 读文字缓存 txt_mem[字序号] → 得到"字库索引"(ccode)
//      第 2 拍 : 用 字库索引*16+行号 去读字库 ROM（ROM 自带 1 拍延迟）
//      第 3 拍 : 字模像素出来了 → 决定这个点画白字还是画压暗的背景
//      第 4 拍 : 输出寄存（S_rgb_r）
//      所以 RGB 和 hs/vs/de 统一延迟 4 拍，用 video_sync_delay #(.STAGES(4))
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module marquee_osd #(
    parameter integer CLK_FREQ  = 25_000_000,   // 视频时钟频率 25MHz
    parameter integer SPEED_PPS = 50,           // 滚动速度（像素/秒）★ 用户要求 50
    parameter integer PAUSE_MS  = 2000          // 两轮之间的间隔（毫秒）
)(
    input  wire        video_clk,      // 视频时钟 25MHz
    input  wire        rst,            // 高有效复位

    // ---------------- 像素输入 ----------------
    input  wire        I_de,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,

    // ---------------- 像素输出（比输入晚 3 拍）----------------
    output wire        O_de,
    output wire        O_hs,
    output wire        O_vs,
    output wire [23:0] O_rgb,

    // ---------------- 显示控制 ----------------
    input  wire        I_show,         // 1 = 显示字幕（SW4 拨到 ON）  0 = 完全透明

    // ---------------- 来自 txt_read 的字符索引（翻转握手）----------------
    input  wire [9:0]  I_idx,          // 字库索引
    input  wire        I_req_tgl,      // 请求（每来一个字符翻转一次）
    output reg         O_ack_tgl,      // 应答（收到后翻转回去）

    // ---------------- 调试输出 ----------------
    output wire [9:0]  O_text_len      // 已经收到的字符数
);

    //==========================================================================
    //  版面参数
    //==========================================================================
    localparam [9:0] BAND_Y0 = 10'd440;   // 底条上沿
    localparam [9:0] TEXT_Y0 = 10'd452;   // 文字第一行（垂直居中于底条）
    localparam [9:0] TEXT_Y1 = 10'd468;   // 文字最后一行 +1

    // 半透明白字配色
    localparam [23:0] COL_TEXT = 24'hFFFFFF;   // 文字：纯白

    // 速度换算
    localparam integer PIX_DIV = CLK_FREQ / SPEED_PPS;          // 多少拍走 1 像素
    localparam integer PAUSE_N = CLK_FREQ / 1000 * PAUSE_MS;    // 暂停多少拍

    //==========================================================================
    //  第 1 部分：像素坐标追踪
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
    //  第 2 部分：滚动控制（产生 scroll_pos）
    //==========================================================================
    reg [9:0]  text_len;      // 已经收到多少个字符
    reg [18:0] pix_cnt;       // 像素节拍计数器
    reg [25:0] pause_cnt;     // 暂停计数器
    reg [15:0] scroll_pos;    // 已经滚过去的像素数
    reg        scrolling;     // 1 = 正在滚   0 = 暂停中

    // 一轮总滚动距离 = 屏幕宽 640 + 文字总宽
    wire [15:0] text_w    = {6'b0, text_len} << 4;         // text_len * 16
    wire [15:0] total_run = 16'd640 + text_w;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            scroll_pos <= 16'd0;
            scrolling  <= 1'b1;
            pix_cnt    <= 19'd0;
            pause_cnt  <= 26'd0;
        end else if (text_len == 10'd0) begin
            // 还没收到任何字符（或者卡上根本没有字幕文件）→ 停在起点
            scroll_pos <= 16'd0;
            scrolling  <= 1'b1;
            pix_cnt    <= 19'd0;
            pause_cnt  <= 26'd0;
        end else if (scrolling) begin
            if (pix_cnt >= PIX_DIV - 1) begin
                pix_cnt <= 19'd0;
                if (scroll_pos >= total_run) begin
                    // 整条文字已经全部滚出左边 → 进入暂停
                    // （scroll_pos 保持在原位，底条空着，视觉上更自然）
                    scrolling <= 1'b0;
                    pause_cnt <= 26'd0;
                end else begin
                    scroll_pos <= scroll_pos + 16'd1;
                end
            end else begin
                pix_cnt <= pix_cnt + 19'd1;
            end
        end else begin
            // ---- 暂停中 ----
            if (pause_cnt >= PAUSE_N - 1) begin
                pause_cnt  <= 26'd0;
                scroll_pos <= 16'd0;        // 回到右边缘，重新开始
                scrolling  <= 1'b1;
            end else begin
                pause_cnt <= pause_cnt + 26'd1;
            end
        end
    end

    //==========================================================================
    //  第 3 部分：接收跨时钟域来的字符索引（翻转握手）
    //    两边都在 video_clk 域读写 txt_mem，所以是"单时钟 RAM"，不需要双口
    //==========================================================================
    reg [9:0] txt_mem [0:511];         // 512 个字符的文字缓存
    reg       req_s1, req_s2;          // I_req_tgl 的两级同步器

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            req_s1   <= 1'b0;
            req_s2   <= 1'b0;
            O_ack_tgl <= 1'b0;
            text_len <= 10'd0;
        end else begin
            req_s1 <= I_req_tgl;
            req_s2 <= req_s1;

            if (req_s2 != O_ack_tgl) begin
                // ---- 对端送来一个新字符 ----
                if (text_len < 10'd512) begin
                    txt_mem[text_len[8:0]] <= I_idx;
                    text_len <= text_len + 10'd1;
                end
                O_ack_tgl <= req_s2;      // 应答：告诉对端可以送下一个
            end
        end
    end

    assign O_text_len = text_len;

    //==========================================================================
    //  第 4 部分：流水线第 0 拍 —— 算出这个像素要显示什么
    //==========================================================================
    wire in_band = (S_y >= BAND_Y0);                        // 落在底条范围内

    // 像素在文本里的相对位置（见文件头算法说明）
    wire [16:0] x_plus_scroll = {7'b0, S_x} + {1'b0, scroll_pos};
    wire        rel_ok        = (x_plus_scroll >= 17'd640);
    wire [16:0] rel           = x_plus_scroll - 17'd640;

    wire        in_text = in_band &&
                          (S_y >= TEXT_Y0) && (S_y < TEXT_Y1) &&
                          rel_ok && (rel < {1'b0, text_w});

    wire [9:0]  cidx = rel[13:4];        // 第几个字符（rel>>4）
    wire [3:0]  pxin = rel[3:0];         // 字符内第几列（0=最左）
    wire [3:0]  row  = S_y - TEXT_Y0;    // 字模第几行

    //==========================================================================
    //  第 5 部分：流水线第 1 / 2 / 3 拍
    //==========================================================================
    reg        band1, band2, band3;
    reg        txt1,  txt2,  txt3;
    reg [3:0]  px1,   px2,   px3;
    reg [3:0]  row1,  row2;
    reg [9:0]  cidx1;
    reg [23:0] rgb1, rgb2, rgb3;

    // ---- 第 1 拍：寄存"要哪个字 / 哪一列" ----
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            band1 <= 1'b0;  txt1 <= 1'b0;  px1 <= 4'd0;  row1 <= 4'd0;
            cidx1 <= 10'd0; rgb1 <= 24'd0;
        end else begin
            band1 <= in_band;
            txt1  <= in_text;
            px1   <= pxin;
            row1  <= row;
            cidx1 <= cidx;
            rgb1  <= I_rgb;
        end
    end

    // ---- 第 1 拍组合：读文字缓存（综合成块 RAM，1 拍延迟）----
    reg [9:0] ccode2;
    always @(posedge video_clk) ccode2 <= txt_mem[cidx1[8:0]];

    // ---- 第 2 拍：寄存"字库索引 / 行号"，送字库地址 ----
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            band2 <= 1'b0;  txt2 <= 1'b0;  px2 <= 4'd0;  row2 <= 4'd0;  rgb2 <= 24'd0;
        end else begin
            band2 <= band1;
            txt2  <= txt1;
            px2   <= px1;
            row2  <= row1;
            rgb2  <= rgb1;
        end
    end

    // ---- 第 2 拍组合：字库地址 = 索引*16 + 行号 ----
    wire [13:0] faddr = {ccode2, 4'b0} + {10'b0, row2};
    wire [15:0] fdata;

    marquee_font u_marquee_font (
        .clk  (video_clk),
        .addr (faddr),
        .data (fdata)
    );

    // ---- 第 3 拍：字模像素出来了，决定画什么 ----
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            band3 <= 1'b0;  px3 <= 4'd0;  rgb3 <= 24'd0;  txt3 <= 1'b0;
        end else begin
            band3 <= band2;
            px3   <= px2;
            rgb3  <= rgb2;
            txt3  <= txt2;      // ★ 必须和 band3/px3 同步再打一拍，否则文字横向错 1 像素
        end
    end

    // 字模这一行里，第 px3 列是不是点亮的
    //   字库数据 bit15 在最左边，所以列号要反过来取
    wire font_on = fdata[4'd15 - px3];

    // 底条背景：原画面亮度减半（右移 1 位，每通道最高位补 0）
    wire [23:0] dim_rgb = {1'b0, rgb3[23:17],
                           1'b0, rgb3[15:9],
                           1'b0, rgb3[7:1]};

    reg [23:0] S_rgb_r;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            S_rgb_r <= 24'd0;
        end else if (!I_show || !band3) begin
            // 字幕开关关掉 或 不在底条范围内 → 完全透明
            S_rgb_r <= rgb3;
        end else if (txt3 && font_on) begin
            S_rgb_r <= COL_TEXT;      // 白字
        end else begin
            S_rgb_r <= dim_rgb;       // 压暗的底条
        end
    end

    assign O_rgb = S_rgb_r;

    // ★ 同步信号必须延迟与 RGB 相同的拍数
    //   RGB 经过：rgb1 → rgb2 → rgb3 → S_rgb_r，共 4 级寄存器，所以是 4 拍。
    //   （写少了画面左右偏移、AXIS 的 SOF/EOF 判错导致撕裂）
    video_sync_delay #(.STAGES(4)) u_sync_delay (
        .clk    (video_clk),
        .I_sync ({I_hs, I_vs, I_de}),
        .O_sync ({O_hs, O_vs, O_de})
    );

endmodule
