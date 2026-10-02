//==============================================================================
//  文件名  : wav_read.v
//  模块名  : wav_read
//  功能    : 从 TF 卡扫描 WAV 文件、解析文件头、流式输出 PCM 采样
//------------------------------------------------------------------------------
//  【对应赛题】基础要求④"HDMI 音频输出"的实质实现
//             也是合规要求"音频处理方法不能与参考例程相同"的关键：
//             例程是内部算法生成方波音阶，我们是从 TF 卡读真实音乐文件。
//
//  【工作流程】
//    ① W_SCAN  逐扇区扫描，找 WAV 文件（识别 "RIFF" + "WAVE" 特征码）
//    ② W_HDR   解析刚读到的那一扇区里的 44 字节文件头
//    ③ W_DATA  从 data 数据区流式读出 PCM，每 4 字节拼成一个立体声采样
//    ④ 数据读完后自动回到数据区开头 → 音乐无缝循环
//
//  【支持的格式】（由 tools/normalize_wav.py 保证）
//      PCM / 48000 Hz / 16 bit / 立体声 / 标准 44 字节头
//      文件格式不对时会在 wav_err_code 上给出错误码，便于数码管/OSD 显示
//
//  【数据打包方式】
//      WAV 里 16bit 立体声的排布是：L低字节, L高字节, R低字节, R高字节
//      我们每收满 4 个字节，拼成一个 32bit 字：{R[15:0], L[15:0]}
//      这个格式正好是 audio_player 和 HDMI 发射核要的。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module wav_read #(
    parameter [31:0] START_SECTOR = 32'd0      // 扫描起始扇区
)(
    input  wire        clk,                    // sd_card_clk = 100MHz
    input  wire        rst,

    // ---------------- 扫描控制 ----------------
    input  wire        scan_start,             // 启动扫描（单拍脉冲）
    input  wire [31:0] scan_max_sector,        // 扫描范围上限
    output reg         scan_done,              // 扫描结束
    output reg         scan_found,             // 是否找到 WAV
    output reg  [31:0] scan_found_sector,      // WAV 文件起始扇区
    output reg  [3:0]  wav_err_code,           // 错误码（0=正常）

    // ---------------- 播放控制 ----------------
    input  wire        play_en,                // 1=播放（持续请求读数据）

    // ---------------- SD 总线（接 sd_bus_arbiter 的 WAV 通道）----------------
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,

    // ---------------- PCM 输出（写音频 FIFO）----------------
    output reg         pcm_wr_en,              // 写使能（每帧一个脉冲）
    output reg  [31:0] pcm_data,               // {R[15:0], L[15:0]}

    output reg  [3:0]  state_code              // 状态码（送数码管）
);

    //--------------------------------------------------------------------------
    // 状态编码
    //--------------------------------------------------------------------------
    localparam [2:0] W_IDLE = 3'd0;   // 等待扫描命令
    localparam [2:0] W_SCAN = 3'd1;   // 逐扇区找 WAV 文件
    localparam [2:0] W_HDR  = 3'd2;   // 解析文件头
    localparam [2:0] W_DATA = 3'd3;   // 流式输出 PCM
    localparam [2:0] W_ERR  = 3'd4;   // 格式不支持，停在错误码

    reg [2:0] state;
    assign state_code = {1'b0, state};

    //--------------------------------------------------------------------------
    // 错误码定义（在数码管/OSD 上显示，方便排查）
    //--------------------------------------------------------------------------
    localparam [3:0] E_OK       = 4'd0;   // 正常
    localparam [3:0] E_NOT_PCM  = 4'd1;   // 不是 PCM 编码
    localparam [3:0] E_BAD_RATE = 4'd2;   // 采样率不是 48kHz
    localparam [3:0] E_BAD_BITS = 4'd3;   // 位深不是 16bit
    localparam [3:0] E_BAD_CHAN = 4'd4;   // 声道数不是 2
    localparam [3:0] E_NO_DATA  = 4'd5;   // 找不到 data 块
    localparam [3:0] E_NO_FILE  = 4'd6;   // 扫不到 WAV 文件

    //--------------------------------------------------------------------------
    // 扫描相关
    //--------------------------------------------------------------------------
    reg [31:0] scan_sector;              // 当前扫描到的扇区
    reg [5:0]  hdr_cnt;                  // 头部字节计数 0..43
    reg [7:0]  hdr [0:43];               // 44 字节标准 WAV 头缓存

    //--------------------------------------------------------------------------
    // 文件头解析结果
    //--------------------------------------------------------------------------
    reg [31:0] data_offset;              // data 数据区在文件内的字节偏移
    reg [31:0] data_size;                // data 数据区字节数
    reg [31:0] data_start_sector;        // data 区起始扇区

    //--------------------------------------------------------------------------
    // 播放相关
    //--------------------------------------------------------------------------
    reg [31:0] file_byte_cnt;            // 文件内绝对字节偏移
    reg [1:0]  byte_in_frame;            // 帧内字节序号 0..3
    reg [31:0] sample_buf;               // 采样拼接缓存

    //==========================================================================
    //  主状态机
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= W_IDLE;
            scan_sector       <= START_SECTOR;
            hdr_cnt           <= 6'd0;
            scan_done         <= 1'b0;
            scan_found        <= 1'b0;
            scan_found_sector <= 32'd0;
            wav_err_code      <= E_OK;
            sd_sec_read       <= 1'b0;
            sd_sec_read_addr  <= 32'd0;
            pcm_wr_en         <= 1'b0;
            pcm_data          <= 32'd0;
            file_byte_cnt     <= 32'd0;
            byte_in_frame     <= 2'd0;
            data_offset       <= 32'd0;
            data_size         <= 32'd0;
            data_start_sector <= 32'd0;
        end else begin
            pcm_wr_en <= 1'b0;      // 写使能默认拉低，只在拼满一帧时拉高一拍

            case (state)

                //==========================================================
                // 等待扫描命令
                //==========================================================
                W_IDLE: begin
                    sd_sec_read <= 1'b0;
                    if (scan_start) begin
                        scan_sector  <= START_SECTOR;
                        hdr_cnt      <= 6'd0;
                        scan_done    <= 1'b0;
                        scan_found   <= 1'b0;
                        wav_err_code <= E_OK;
                        state        <= W_SCAN;
                    end
                end

                //==========================================================
                // 逐扇区扫描，找 "RIFF" + "WAVE"
                //==========================================================
                W_SCAN: begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= scan_sector;

                    // 收集扇区前 44 字节
                    if (sd_sec_read_data_valid && (hdr_cnt < 6'd44)) begin
                        hdr[hdr_cnt] <= sd_sec_read_data;
                        hdr_cnt      <= hdr_cnt + 6'd1;
                    end

                    if (sd_sec_read_end) begin
                        hdr_cnt <= 6'd0;
                        // 特征码判断：偏移 0..3 = "RIFF"，偏移 8..11 = "WAVE"
                        if ((hdr[0] == 8'h52) && (hdr[1] == 8'h49) &&      // "RI"
                            (hdr[2] == 8'h46) && (hdr[3] == 8'h46) &&      // "FF"
                            (hdr[8] == 8'h57) && (hdr[9] == 8'h41) &&      // "WA"
                            (hdr[10] == 8'h56) && (hdr[11] == 8'h45)) begin // "VE"
                            // 找到了！刚刚这一扇区就含有完整文件头，直接解析
                            scan_found        <= 1'b1;
                            scan_found_sector <= scan_sector;
                            state             <= W_HDR;
                        end else if (scan_sector >= scan_max_sector) begin
                            // 扫到头了还没找到
                            scan_done    <= 1'b1;
                            scan_found   <= 1'b0;
                            wav_err_code <= E_NO_FILE;
                            state        <= W_ERR;
                        end else begin
                            scan_sector <= scan_sector + 32'd1;
                        end
                    end
                end

                //==========================================================
                // 解析 44 字节标准 WAV 头
                //==========================================================
                W_HDR: begin
                    sd_sec_read <= 1'b0;
                    scan_done   <= 1'b1;

                    // 偏移 20..21 音频格式：1 = PCM
                    // 偏移 22..23 声道数
                    // 偏移 24..27 采样率
                    // 偏移 34..35 位深
                    // 偏移 36..39 "data" 标记
                    // 偏移 40..43 数据长度
                    if ({hdr[21], hdr[20]} != 16'd1) begin
                        wav_err_code <= E_NOT_PCM;  state <= W_ERR;
                    end else if ({hdr[23], hdr[22]} != 16'd2) begin
                        wav_err_code <= E_BAD_CHAN; state <= W_ERR;
                    end else if ({hdr[27], hdr[26], hdr[25], hdr[24]} != 32'd48000) begin
                        wav_err_code <= E_BAD_RATE; state <= W_ERR;
                    end else if ({hdr[35], hdr[34]} != 16'd16) begin
                        wav_err_code <= E_BAD_BITS; state <= W_ERR;
                    end else if ({hdr[39], hdr[38], hdr[37], hdr[36]} != 32'h61746164) begin
                        // "data" 的 ASCII 是 0x64 0x61 0x74 0x61，小端拼起来 = 0x61746164
                        wav_err_code <= E_NO_DATA;  state <= W_ERR;
                    end else begin
                        // ---- 全部合格，准备播放 ----
                        data_offset       <= 32'd44;                 // 标准头长度
                        data_size         <= {hdr[43], hdr[42], hdr[41], hdr[40]};
                        data_start_sector <= 32'd0;                  // 44/512 = 0 号扇区
                        file_byte_cnt     <= 32'd0;
                        byte_in_frame     <= 2'd0;
                        wav_err_code      <= E_OK;
                        state             <= W_DATA;
                    end
                end

                //==========================================================
                // 流式输出 PCM
                //==========================================================
                W_DATA: begin
                    // 持续请求读扇区（arbiter 会根据 FIFO 水位决定何时给）
                    sd_sec_read <= play_en;

                    // ---- 每收到一个字节 ----
                    if (sd_sec_read_data_valid) begin
                        // 只在 data 数据区范围内才计入采样
                        if ((file_byte_cnt >= data_offset) &&
                            (file_byte_cnt <  data_offset + data_size)) begin
                            case (byte_in_frame)
                                2'd0: sample_buf[7:0]   <= sd_sec_read_data;  // L 低
                                2'd1: sample_buf[15:8]  <= sd_sec_read_data;  // L 高
                                2'd2: sample_buf[23:16] <= sd_sec_read_data;  // R 低
                                2'd3: ;                                       // R 高（下面直接用）
                            endcase

                            if (byte_in_frame == 2'd3) begin
                                // 收满一帧：拼成 {R[15:0], L[15:0]} 写入 FIFO
                                pcm_wr_en     <= 1'b1;
                                pcm_data      <= {sd_sec_read_data, sample_buf[23:0]};
                                byte_in_frame <= 2'd0;
                            end else begin
                                byte_in_frame <= byte_in_frame + 2'd1;
                            end
                        end
                        file_byte_cnt <= file_byte_cnt + 32'd1;
                    end

                    // ---- 一个扇区读完 ----
                    if (sd_sec_read_end) begin
                        byte_in_frame <= 2'd0;
                        if (file_byte_cnt >= (data_offset + data_size)) begin
                            // ★ 数据读完 → 无缝循环：回到数据区开头
                            sd_sec_read_addr <= data_start_sector;
                            file_byte_cnt    <= 32'd0;
                        end else begin
                            sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        end
                    end
                end

                //==========================================================
                // 格式不支持：停在错误码，等待重新扫描
                //==========================================================
                W_ERR: begin
                    sd_sec_read <= 1'b0;
                    if (scan_start) begin
                        scan_sector  <= START_SECTOR;
                        hdr_cnt      <= 6'd0;
                        scan_done    <= 1'b0;
                        scan_found   <= 1'b0;
                        wav_err_code <= E_OK;
                        state        <= W_SCAN;
                    end
                end

                default: state <= W_IDLE;
            endcase
        end
    end

endmodule
