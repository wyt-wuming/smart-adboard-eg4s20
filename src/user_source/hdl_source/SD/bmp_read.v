//==============================================================================
//  文件名  : bmp_read.v
//  模块名  : bmp_read
//  功能    : BMP 图片扫描与读取（支持任意尺寸，流式输出像素）
//  时钟域  : sd_card_clk（100MHz）
//  说明    : 本作品改造：支持任意宽高(<=2048)+输出真实尺寸 O_img_w/O_img_h 与首像素 O_frame_start，供 img_scaler 缩放
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================

module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // ---------------- ★ 源图真实尺寸（给 img_scaler 用）----------------
    //   像素流是一维的，缩放器必须知道"一行有多少个像素"才能切行，
    //   以及"一共多少行"才能算纵向缩放比。
    output wire [15:0]          O_img_w,
    output wire [15:0]          O_img_h,
    output wire                 O_frame_start   // 新图第一个像素（给缩放器复位用）
);

// ★【重要】下面这几个寄存器必须声明在"第一次使用之前"（就是这里）：
//   信号若在"使用之后"才声明，综合器会先建一条 1 位宽的隐式线网（HDL-7225），
//   32 位的比较/选择被截断 → O_frame_start / O_img_w / O_img_h 出错 →
//   img_scaler 缩放画面错乱（行缓存复位时机错、缩放比例错）。
//   （原代码把它们声明在文件后部，属于真实隐患，2026-10-05 整理时上移到这里）
reg [31:0] bmp_len_cnt;     // 像素计数器（当前图已收到的原始像素数）
reg [31:0] pixel_offset;    // BMP 头解析出的像素数据起始偏移
reg [31:0] width;           // 源图宽（BMP 头）
reg [31:0] height;          // 源图高（BMP 头）

// 一张图里"第一个有效像素"：给 img_scaler 当"新一帧开始"的复位脉冲。
//   ★ 关键时序：像素是 3 个字节拼出来的 ——
//       2'd0 存 B、2'd1 存 G、2'd2 存 R 并把 bmp_data_wr_en 拉高。
//     所以当 bmp_data_wr_en 第一次有效时，字节计数器已经走到
//       pixel_offset + 3（不是 pixel_offset！）
//   ★ 2026-10-06 修复：原来写成 "== pixel_offset"，该信号**永远为 0** →
//     img_scaler 永远等不到帧开始（卡在 S_IDLE）→ 图片装载永远不完成
//     → 屏幕全黑，且图片通路持续占用 SD 总线，音乐也被饿死。
//--------------------------------------------------------------------------
//  ★ 为什么把它从 1 拍拉长到 8 拍（2026-10-06 修复）
//    原来它是 1 拍宽（10ns）的脉冲，而接收方 img_scaler 只在 S_IDLE
//    状态才会接住它。给一点余量，让它更容易被接住。
//
//  ★★ 长度上限有硬约束：**必须远小于源像素的到达间隔（约 106 拍）**！
//    img_scaler 的内部逻辑是：
//        else if (I_frame_start) wp <= 11'd1;   // 电平期间每拍都把写指针钉在 1
//    如果这个电平比像素间隔还长，电平期间到达的像素会被写指针"钉住"，
//    全部写进同一个位置 → 行缓存数据错位 → 画面异常。
//    （曾经拉长到 255 拍，超过 106 拍，就踩了这个坑）
//    8 拍 << 106 拍：只覆盖第一个像素那一下，期间不会有第二个像素到达。
//--------------------------------------------------------------------------
reg [7:0] fs_hold;                      // 0 = 无帧开始信号；非 0 = 保持期剩余拍数

always @(posedge clk or posedge rst) begin
    if (rst)
        fs_hold <= 8'd0;
    else if (bmp_data_wr_en && (bmp_len_cnt == (pixel_offset + 32'd3)))
        fs_hold <= 8'd8;                // 检测到第一个像素 → 保持 8 拍
    else if (fs_hold != 8'd0)
        fs_hold <= fs_hold - 8'd1;      // 保持期内逐拍递减
end

assign O_frame_start = (fs_hold != 8'd0);

// 把 BOM 头里解析出来的真实宽高送出去（原来只用于"和 640x480 比对"，
// 现在改成送给缩放器当缩放依据）
assign O_img_w = width[15:0];
assign O_img_h = height[15:0];

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

//--------------------------------------------------------------------------
//  ★ 扫描超时兜底（2026-10-06 加）
//    扫描是逐扇区推进的，大卡扫一遍要几十秒甚至更久，
//    期间数码管最左位一直停在 2，看起来就像死机。
//    这里给扫描加一个上限：到点就带着"已经找到的图"继续往下走。
//    宁可少显示几张，也不要让用户面对一个永远不动的黑屏。
//--------------------------------------------------------------------------
localparam [31:0] SCAN_TIMEOUT_MAX = 32'd1_000_000_000;   // 10 秒 @100MHz
reg [31:0] scan_timeout;

always @(posedge clk or posedge rst) begin
    if (rst || scan_done)
        scan_timeout <= 32'd0;
    else if ((state == ST_SCAN) && (scan_timeout < SCAN_TIMEOUT_MAX))
        scan_timeout <= scan_timeout + 32'd1;
end

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [1:0]  bmp_byte_idx;

// ★ BMP 行填充（padding）支持用的寄存器
//    BMP 规定每行字节数必须是 4 的倍数，不足要在行尾补 0。
//    宽度 W 不是 4 的倍数时，每行末尾就有若干填充字节，必须跳过，
//    否则每行都会错位几列 → 画面出现"横向条纹"花屏。
//    ★ 填充字节数 = W mod 4（因为 3W ≡ -W (mod 4)），直接取 width 的低 2 位即可，
//      不需要任何乘法器。
//    col_pix = 本行已经输出到第几个像素；pad_cnt = 本行还要跳过几个填充字节。
wire [15:0] row_w = (width[15:0] == 16'd0) ? 16'd1 : width[15:0];
reg [15:0] col_pix;
reg [1:0]  pad_cnt;

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign ready = (state == ST_IDLE);
// ★ 原来这里要求"宽高必须正好等于 640x480"，
//   不符合的图直接跳过。现在改成"接受任意尺寸"，由下游 img_scaler
//   负责等比缩放到 480 高。这里只保留几条底线：
//     ① 必须是标准 24 位、无压缩的 BMP
//     ② 宽高要在合理范围内（行缓存 2048 深，超了装不下）
//   ★ 顺带一提：用无符号比较"<= 2048"还能顺便挡掉"自下而上"格式
//     把高度写成负数的情况（负数的低 32 位会是个天文数字，必然超限）。
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (width        <= 32'd2048) &&
                      (height       <= 32'd2048) &&
                      (width        != 32'd0) &&
                      (height       != 32'd0);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
        col_pix      <= 16'd0;
        pad_cnt      <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (pad_cnt != 2'd0) begin
            // ★ 行尾填充字节：只消耗计数，不组装像素
            pad_cnt      <= pad_cnt - 2'd1;
            bmp_byte_idx <= 2'd0;
        end else if (bmp_data_valid) begin
            if (bmp_byte_idx == 2'd2) begin
                bmp_byte_idx <= 2'd0;
                // 本行最后一个像素组装完了 → 列计数归零，准备跳过行尾填充
                if (col_pix + 16'd1 >= row_w) begin
                    col_pix <= 16'd0;
                    pad_cnt <= width[1:0];      // ★ 填充字节数 = W mod 4
                end else begin
                    col_pix <= col_pix + 16'd1;
                end
            end else begin
                bmp_byte_idx <= bmp_byte_idx + 2'd1;
            end
        end
    end else begin
        bmp_byte_idx <= 2'd0;
        col_pix      <= 16'd0;
        pad_cnt      <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (pad_cnt != 2'd0) begin
            // ★ 行尾填充字节：不输出像素
            bmp_data_wr_en <= 1'b0;
        end else if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                // ★ 扫描超时兜底：到点就用"已经找到的图"继续往下走
                if (scan_timeout >= SCAN_TIMEOUT_MAX) begin
                    scan_done <= 1'b1;
                    state     <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
