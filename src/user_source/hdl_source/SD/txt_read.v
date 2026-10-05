//==============================================================================
//  文件名  : txt_read.v
//  模块名  : txt_read
//  功能    : 从 TF 卡扫描并读取字幕文本文件，解码 UTF-8 汉字，输出字库索引
//------------------------------------------------------------------------------
//  【对应赛题】加分项①"OSD 字幕叠加"的数据来源
//
//  【工作流程】
//    ① T_SCAN  逐扇区扫描，找"字幕文件"（识别开头 6 字节 #ZIMU#）
//    ② T_PROC  把整扇区逐字节处理：UTF-8 解码 → 查字库索引表 → 握手送出
//    ③ 送到 512 个字符为止，或者遇到结束标志
//
//  【怎么识别"这是字幕文件"？】
//    TXT 文件没有像 BMP 的 "BM"、WAV 的 "RIFF" 那样的特征码，
//    所以本设计规定：字幕文件的开头必须是 6 个字符  #ZIMU#
//        ┌──────────────────────────────────┐
//        │ #ZIMU#                            │  ← 固定标记（占 6 字节）
//        │ 安路科技 智能数字广告牌 欢迎光临     │  ← 正文（UTF-8 编码）
//        └──────────────────────────────────┘
//    扫描时逐个扇区比较前 6 个字节，命中就是字幕文件。
//
//  【为什么是 UTF-8 而不是 GBK？】
//    Windows 记事本现在默认就是 UTF-8，汉字占 3 个字节：
//        世 = E4 B8 96   → Unicode 码点 0x4E16
//    解码公式：
//        码点 = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
//
//  【为什么要先把整扇区缓存起来？】
//    SD 卡一旦发出 CMD17 就不能暂停，数据会以每拍一个字节的速度吐出来。
//    而"查字库索引表"需要最多 745 拍，期间根本来不及接收数据。
//    所以先把 512 字节整扇区收进 sbuf[]，读完了再慢慢处理，避免丢字节。
//
//  【跨时钟域怎么送出去？】
//    本模块在 sd_card_clk(100MHz) 域，显示模块在 video_clk(25MHz) 域。
//    用"翻转握手"（和工程里已经验证过的 cfg_cdc.v 同一套思路）：
//        本模块：把索引摆好 → 翻转 O_req_tgl → 等 I_ack_tgl 追上来 → 再送下一个
//        对端  ：同步 O_req_tgl，发现翻转了 → 取走索引 → 翻转 I_ack_tgl
//    数据在"翻转请求 → 收到应答"期间保持不动，所以跨域是安全的。
//    这个握手只在"上电加载一次"时用，速度慢无所谓（745 字 x 几百 ns ≈ 几百 µs）。
//
//  【★ 索引位宽必须 ≥10 位】
//    字库一共 841 个字符（95 ASCII + 745 汉字 + 1 个空白），
//    最大索引 840 —— 用 8 位（最大 255）装不下！所以 O_idx 是 10 位。
//    （曾经写成 8 位，会导致索引回绕、显示错字，切记）
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module txt_read (
    input  wire        clk,                    // sd_card_clk = 100MHz
    input  wire        rst,

    // ---------------- 扫描控制 ----------------
    input  wire        scan_start,             // 启动扫描（单拍脉冲）
    input  wire [31:0] scan_max_sector,        // 扫描范围上限
    output reg         scan_done,              // 加载结束（找到并处理完）
    output reg         scan_found,             // 是否找到字幕文件
    output reg  [2:0]  txt_err_code,           // 错误码（0=正常）

    // ---------------- SD 总线（接 sd_bus_arbiter 的 TXT 通道）----------------
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,

    // ---------------- 跨时钟域索引输出（翻转握手）----------------
    output reg  [9:0]  O_idx,                  // 要送出的字库索引
    output reg         O_req_tgl,              // 请求（每送一个字符翻转一次）
    input  wire        I_ack_tgl,              // 对端应答（同样翻转）

    // ---------------- 调试输出 ----------------
    output wire [3:0]  state_code              // 状态码（送数码管/调试）
                                               // ★ 必须用 wire：下面用 assign 赋值
);

    //==========================================================================
    //  参数定义
    //==========================================================================
    localparam [9:0]  MAX_CHARS   = 10'd512;      // 最多接收多少个字符
    localparam [9:0]  IDX_CN_BASE = 10'd96;       // 汉字索引起点（和字库脚本一致）
    localparam [9:0]  CN_LAST     = 10'd744;      // 码点表最后一条的序号

    // 字幕文件标记 "#ZIMU#"
    //   # = 0x23   Z = 0x5A   I = 0x49   M = 0x4D   U = 0x55   # = 0x23
    localparam [7:0] MK0 = 8'h23, MK1 = 8'h5A, MK2 = 8'h49;
    localparam [7:0] MK3 = 8'h4D, MK4 = 8'h55, MK5 = 8'h23;

    //--------------------------------------------------------------------------
    // 错误码
    //--------------------------------------------------------------------------
    localparam [2:0] E_OK      = 3'd0;   // 正常
    localparam [2:0] E_NO_FILE = 3'd1;   // 扫不到字幕文件
    localparam [2:0] E_NO_TEXT = 3'd2;   // 找到文件但里面没字

    //==========================================================================
    //  状态机定义
    //==========================================================================
    localparam [2:0] T_IDLE = 3'd0;   // 等待扫描命令
    localparam [2:0] T_BPB  = 3'd1;   // 读 0 号扇区，取出"每簇几个扇区"
    localparam [2:0] T_SCAN = 3'd2;   // 扫描扇区 + 整扇区缓存
    localparam [2:0] T_PROC = 3'd3;   // 逐字节解码 / 查表 / 送出
    localparam [2:0] T_DONE = 3'd4;   // 全部完成
    localparam [2:0] T_ERR  = 3'd5;   // 出错
    localparam [2:0] T_BPB2 = 3'd6;   // 读"分区起始扇区"上的真 BPB

    // T_PROC 内部的子状态
    localparam [2:0] P_FETCH  = 3'd0; // 取下一个字节，判断类型
    localparam [2:0] P_CN1    = 3'd1; // 取 UTF-8 第 2 字节
    localparam [2:0] P_CN2    = 3'd2; // 取 UTF-8 第 3 字节
    localparam [2:0] P_LOOKUP = 3'd3; // 在码点表里线性查找
    localparam [2:0] P_EMIT   = 3'd4; // 把索引摆到总线上，翻转请求
    localparam [2:0] P_WAIT   = 3'd5; // 等待对端应答

    reg [2:0] state;
    reg [2:0] psub;

    assign state_code = {1'b0, state};

    //==========================================================================
    //  内部寄存器
    //==========================================================================
    reg [31:0] scan_sector;               // 当前扫描扇区
    reg [7:0]  clu_step;                  // 扫描步长 = 每簇几个扇区
    reg [31:0] part_lba;                  // 分区起始扇区（MBR 里读出来的）

    //--------------------------------------------------------------------------
    //  ★★ 扇区前 6 字节的移位寄存器（用来识别 #ZIMU# 标记）★★
    //
    //  【为什么不用 sbuf[0]~sbuf[5] 直接比较？—— 这是个真实的坑】
    //    sbuf 是 512 字节缓存。如果只按"变量地址"读写（扫描时顺序写、
    //    处理时顺序读），TD 会把它识别成块 RAM（BRAM），只占 1 块 ERAM。
    //    但只要出现一次"常量地址"读（比如 sbuf[0]），TD 就没法用块 RAM 了，
    //    只能摊成 4096 个触发器 + 一棵巨大的多路选择器树 →
    //    布局器直接报 PHY-8023 "Incremental route failed"（资源放不下）。
    //    所以标记字节在读进来的时候就顺手存进这个移位寄存器。
    //--------------------------------------------------------------------------
    reg [47:0] mk_sh;                     // 依次移入 6 个字节

    //--------------------------------------------------------------------------
    //  BPB / MBR 探测用的寄存器（同样是"顺手存"，不回头查 sbuf）
    //    偏移 13     : SecPerClus
    //    偏移 450    : MBR 分区类型
    //    偏移 454~457: 分区起始 LBA（小端）
    //    偏移 510~511: 0x55 0xAA 结束标志
    //--------------------------------------------------------------------------
    reg [8:0]  bp_cnt;
    reg [7:0]  bp_cs;
    reg [7:0]  bp_type;
    reg [7:0]  bp_l0, bp_l1, bp_l2, bp_l3;
    reg [7:0]  bp_sg0, bp_sg1;
    reg [9:0]  buf_cnt;                   // 扇区缓存写指针
    reg [9:0]  ptr;                       // 处理指针（扇区内偏移 0~511）
    reg [9:0]  char_cnt;                  // 已经送出的字符数
    // ★【坑】数组名千万别叫 buf！buf/not/and/or/xor 是 Verilog 的门级原语
    //   关键字（保留字），用它当变量名会直接报
    //   "Verilog 2000 keyword 'buf' used in incorrect context"，整个文件都编译不过。
    //   所以这里叫 sbuf（sector buffer）。
    reg [7:0]  sbuf [0:511];              // 整扇区缓存（512 字节）

    reg [7:0]  b0, b1;                    // UTF-8 中间字节
    reg [15:0] cp;                        // 解出来的 Unicode 码点
    reg [9:0]  emit_idx;                  // 本次要送出的字库索引（★10 位）

    // ---- 查表流水线对齐 ★【这里曾经写错，导致显示的字全部"变成下一个字"】----
    //   码点表 ROM 有 1 拍读延迟：
    //         cmap_code@t  =  mem[ lk_addr@(t-1) ]
    //   而      lk_addr_q1@t =      lk_addr@(t-1)
    //   所以"当拍的 cmap_code"和"当拍的 lk_addr_q1"是严格同拍对齐的。
    //   直接用这两个做比较，命中的位置就是 lk_addr_q1，不多不少。
    //
    //   ✘ 之前错在哪：把 cmap_code 又打了一拍成 cmap_q 再去和"当拍地址"比，
    //     等于拿 t-2 拍的数据对 t-1 拍的地址，永远差一个字，
    //     于是屏幕上所有汉字都变成字典里的下一个字。
    reg [9:0]  lk_addr;                   // 查表地址（送给 ROM）
    reg [9:0]  lk_addr_q1;                // 打一拍，与 cmap_code 同拍对齐
    reg        lk_start;                  // 第 1 拍：只发地址 0，不做比较
    reg        lk_run;                    // 第 2 拍起：可以比较了

    reg [1:0]  ack_sync;                  // I_ack_tgl 的两级同步器

    //==========================================================================
    //  码点表 ROM（由 tools/gen_marquee_font.py 生成）
    //    输入：表项序号 addr    输出：该条目的 Unicode 码点 code（1 拍延迟）
    //==========================================================================
    wire [15:0] cmap_code;
    marquee_cmap u_cmap (
        .clk  (clk),
        .addr (lk_addr),
        .code (cmap_code)
    );

    //==========================================================================
    //  辅助：判断一个字节是不是合法 UTF-8 首字节
    //    < 0x80        : ASCII
    //    0xE0 ~ 0xEF   : 三字节汉字的首字节
    //    其它          : 非法（当成"文本结束"处理）
    //==========================================================================
    // ★ 用 ptr[8:0] 取地址：ptr 是 10 位（会到 512），
    //   而 buf 深度是 512（地址 0~511），直接写 sbuf[ptr] 会越界。
    wire [7:0] cur = sbuf[ptr[8:0]];       // 当前处理指针指向的字节

    wire is_ascii   = (cur >= 8'h20) && (cur <= 8'h7E);
    wire is_cn      = ((cur & 8'hF0) == 8'hE0);
    wire is_nl      = (cur == 8'h0A) || (cur == 8'h0D);    // 换行
    wire is_blank   = (cur == 8'h20) || is_nl;             // 空格或换行

    //==========================================================================
    //  主状态机
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= T_IDLE;
            psub             <= P_FETCH;
            scan_sector      <= 32'd0;
            clu_step         <= 8'd1;
            // ★ 这两个必须复位：上电初值不确定的话，
            //   第一次 BPB 探测的字节偏移会错位（取不到簇大小）
            mk_sh            <= 48'd0;
            bp_cnt           <= 9'd0;
            part_lba         <= 32'd0;
            buf_cnt          <= 10'd0;
            ptr              <= 10'd0;
            char_cnt         <= 10'd0;
            scan_done        <= 1'b0;
            scan_found       <= 1'b0;
            txt_err_code     <= E_OK;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            O_idx            <= 10'd0;
            O_req_tgl        <= 1'b0;
            b0               <= 8'd0;
            b1               <= 8'd0;
            cp               <= 16'd0;
            emit_idx         <= 10'd0;
            lk_addr          <= 10'd0;
            lk_addr_q1       <= 10'd0;
            lk_start         <= 1'b0;
            lk_run           <= 1'b0;
            ack_sync         <= 2'd0;
        end else begin
            // 应答信号的两级同步（跨时钟域必备）
            ack_sync <= {ack_sync[0], I_ack_tgl};

            case (state)

                //==========================================================
                //  等待扫描命令
                //==========================================================
                T_IDLE: begin
                    sd_sec_read <= 1'b0;
                    if (scan_start) begin
                        scan_sector  <= 32'd0;
                        buf_cnt      <= 10'd0;
                        char_cnt     <= 10'd0;
                        scan_done    <= 1'b0;
                        scan_found   <= 1'b0;
                        txt_err_code <= E_OK;
                        state        <= T_BPB;
                    end
                end

                //==========================================================
                //  读 0 号扇区（FAT32 的 BPB），取出"每簇几个扇区"
                //----------------------------------------------------------
                //  【为什么必须做这一步】
                //    字幕文件很小（不到 512 字节），但它在卡上的位置可能很靠后。
                //    比如用户最后才把 ZIMU.TXT 拷进卡里，前面已经躺着
                //    6 张广告图（5.4MB）+ 一首 24MB 的音乐，
                //    那么字幕文件可能在 5 万多个扇区之后。
                //    如果逐个扇区扫描，要扫 5 万多次 x 184µs ≈ 十几秒，太慢，
                //    而且期间一直占着 SD 总线。
                //
                //  【解决办法：按簇边界扫】
                //    FAT32 里"任何文件的第一个字节一定落在簇的边界上"，
                //    而我们的 #ZIMU# 标记就在文件第一个字节。
                //    所以只用扫"簇的起始扇区"就够了，扫描量直接除以簇大小
                //    （典型 64 扇区/簇 → 只要扫 890 次 ≈ 0.16 秒）。
                //
                //  【簇大小从哪来】
                //    FAT32 的 0 号扇区是 BPB（引导参数块），偏移 13 字节
                //    就是"每簇几个扇区"(SecPerClus)。
                //    只认 2 的整数次幂、1~128 的合法值，其它一律退化成 1
                //    （那样会慢，但至少不会错）。
                //==========================================================
                T_BPB: begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= 32'd0;

                    // ★ 只挑需要的字节顺手存进寄存器，绝不回头用常量地址查 sbuf
                    //   （否则 sbuf 做不成块 RAM，布局器会报 PHY-8023 放不下）
                    if (sd_sec_read_data_valid) begin
                        case (bp_cnt)
                            9'd13 : bp_cs   <= sd_sec_read_data;
                            9'd450: bp_type <= sd_sec_read_data;
                            9'd454: bp_l0   <= sd_sec_read_data;
                            9'd455: bp_l1   <= sd_sec_read_data;
                            9'd456: bp_l2   <= sd_sec_read_data;
                            9'd457: bp_l3   <= sd_sec_read_data;
                            9'd510: bp_sg0  <= sd_sec_read_data;
                            9'd511: bp_sg1  <= sd_sec_read_data;
                            default: ;
                        endcase
                        bp_cnt <= bp_cnt + 9'd1;
                    end

                    if (sd_sec_read_end) begin
                        bp_cnt <= 9'd0;
                        if ((bp_sg0 == 8'h55) && (bp_sg1 == 8'hAA) &&
                            ((bp_type == 8'h0B) || (bp_type == 8'h0C))) begin
                            // ---- ★ 0 号扇区是 MBR（分区表），不是 BPB！----
                            //   Windows 格式化 SD 卡会建分区表：
                            //     偏移 450     : 分区类型（0x0B/0x0C = FAT32）
                            //     偏移 454~457 : 第一个分区的起始 LBA（小端）
                            //     偏移 510~511 : 0x55 0xAA 结束标志
                            //   真正的 BPB 在"分区起始扇区"上，去那里取簇大小。
                            //   不处理这一步，取到的簇大小是垃圾值，
                            //   只能退化成逐扇区扫描（要扫十几秒）。
                            part_lba <= {bp_l3, bp_l2, bp_l1, bp_l0};
                            state    <= T_BPB2;
                        end else begin
                            // ---- 0 号扇区本身就是 BPB（超级软盘格式）----
                            case (bp_cs)
                                8'd1, 8'd2, 8'd4, 8'd8,
                                8'd16, 8'd32, 8'd64, 8'd128: begin
                                    clu_step    <= bp_cs;
                                    scan_sector <= {24'd0, bp_cs};
                                end
                                default: begin
                                    clu_step    <= 8'd1;
                                    scan_sector <= 32'd1;
                                end
                            endcase
                            state <= T_SCAN;
                        end
                    end
                end

                //==========================================================
                //  读"分区起始扇区"，那才是真正的 BPB
                //==========================================================
                T_BPB2: begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= part_lba;

                    if (sd_sec_read_data_valid) begin
                        if (bp_cnt == 9'd13) bp_cs <= sd_sec_read_data;
                        bp_cnt <= bp_cnt + 9'd1;
                    end

                    if (sd_sec_read_end) begin
                        bp_cnt <= 9'd0;
                        case (bp_cs)
                            8'd1, 8'd2, 8'd4, 8'd8,
                            8'd16, 8'd32, 8'd64, 8'd128: begin
                                clu_step    <= bp_cs;
                                // 从分区的第一个簇边界开始扫
                                scan_sector <= part_lba + {24'd0, bp_cs};
                            end
                            default: begin
                                clu_step    <= 8'd1;
                                scan_sector <= part_lba + 32'd1;
                            end
                        endcase
                        state <= T_SCAN;
                    end
                end

                //==========================================================
                //  扫描扇区：一边找标记，一边把整扇区缓存下来
                //==========================================================
                T_SCAN: begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= scan_sector;

                    if (sd_sec_read_data_valid) begin
                        if (buf_cnt < 10'd512)
                            sbuf[buf_cnt[8:0]] <= sd_sec_read_data;   // 存整扇区
                        buf_cnt <= buf_cnt + 10'd1;
                        // ★ 顺手把前 6 个字节移进移位寄存器（不要回头查 sbuf[0..5]！）
                        if (buf_cnt < 10'd6)
                            mk_sh <= {mk_sh[39:0], sd_sec_read_data};
                    end

                    if (sd_sec_read_end) begin
                        buf_cnt <= 10'd0;
                        // 比较前 6 个字节是不是 "#ZIMU#"
                        //   "#ZIMU#" 的 ASCII = 23 5A 49 4D 55 23
                        if (mk_sh == 48'h23_5A_49_4D_55_23) begin
                            // ---- 找到了！开始逐字节处理，跳过 6 字节标记 ----
                            scan_found <= 1'b1;
                            ptr        <= 10'd6;
                            psub       <= P_FETCH;
                            lk_start   <= 1'b0;
                            lk_run     <= 1'b0;
                            state      <= T_PROC;
                        end else if (scan_sector >= scan_max_sector) begin
                            // 扫到头了也没有 → 报错，画面照常显示，只是没有字幕
                            scan_done    <= 1'b1;
                            scan_found   <= 1'b0;
                            txt_err_code <= E_NO_FILE;
                            state        <= T_ERR;
                        end else begin
                            // ★ 按"簇"跳，不是按扇区跳（见上面 T_BPB 的说明）
                            scan_sector <= scan_sector + {24'd0, clu_step};
                        end
                    end
                end

                //==========================================================
                //  逐字节处理：UTF-8 解码 → 查表 → 送出
                //==========================================================
                T_PROC: begin
                    sd_sec_read <= 1'b0;      // 处理期间不占总线

                    case (psub)

                        //--------------------------------------------------
                        // 取一个字节，判断它是什么
                        //--------------------------------------------------
                        P_FETCH: begin
                            if (char_cnt >= MAX_CHARS) begin
                                scan_done    <= 1'b1;
                                txt_err_code <= E_OK;
                                state        <= T_DONE;
                            end else if (ptr >= 10'd512) begin
                                // 本扇区处理完了 → 读下一个扇区继续
                                scan_sector <= scan_sector + 32'd1;
                                buf_cnt     <= 10'd0;
                                state       <= T_SCAN;
                            end else if ((char_cnt == 10'd0) &&
                                         ((cur == 8'h0A) || (cur == 8'h0D) ||
                                          (cur == 8'h20) || (cur == 8'h09))) begin
                                // ---- 正文开头的换行/空格：跳过 ----
                                // 方便你在 #ZIMU# 标记后面直接回车换行写广告词：
                                //     #ZIMU#
                                //     安路科技 智能数字广告牌 欢迎光临
                                ptr <= ptr + 10'd1;
                            end else if (cur == 8'h00) begin
                                // ---- 0x00 = 真正的文件结束 ----
                                // 文件只占一个簇的最前面一小段，后面没用到的地方
                                // 格式化过的卡上是全 0，所以遇到 0x00 就是没正文了。
                                scan_done    <= 1'b1;
                                txt_err_code <= (char_cnt == 0) ? E_NO_TEXT : E_OK;
                                state        <= T_DONE;
                            end else if ((char_cnt == 0) && is_blank) begin
                                // ★【关键修正】正文还没开始，先跳过开头的空格/换行！
                                //   用户的字幕文件通常长这样：
                                //        #ZIMU#          ← 第 1 行是标记
                                //        世界计划 ...     ← 第 2 行才是正文
                                //   （标记后面跟着一个 CR LF）
                                //   如果这里把换行当成"文本结束"，就会一个字都读不到，
                                //   屏幕上连一个白字都不出现 —— 曾经就是这样挂掉的，切记！
                                ptr <= ptr + 10'd1;
                            end else if (is_nl) begin
                                // 正文中间的换行 → 当成一个空格
                                // （这样多行广告词也能连成一句滚动）
                                emit_idx <= 10'd1;      // 索引 1 = ASCII 空格
                                ptr      <= ptr + 10'd1;
                                psub     <= P_EMIT;
                            end else if (is_ascii) begin
                                // ---- ASCII（1 字节）：索引 = 码点 - 31 ----
                                emit_idx <= {2'b0, cur} - 10'd31;   // 8bit→10bit 再减
                                ptr      <= ptr + 10'd1;
                                psub     <= P_EMIT;
                            end else if (is_cn) begin
                                // ---- 三字节汉字的首字节 ----
                                b0  <= cur;
                                ptr <= ptr + 10'd1;
                                psub <= P_CN1;
                            end else begin
                                // ---- 不认识的字节（很可能是残留数据）→ 结束 ----
                                scan_done    <= 1'b1;
                                txt_err_code <= (char_cnt == 0) ? E_NO_TEXT : E_OK;
                                state        <= T_DONE;
                            end
                        end

                        //--------------------------------------------------
                        // UTF-8 第 2 字节（必须是 10xxxxxx）
                        //--------------------------------------------------
                        P_CN1: begin
                            if ((cur & 8'hC0) != 8'h80) begin
                                scan_done    <= 1'b1;
                                txt_err_code <= (char_cnt == 0) ? E_NO_TEXT : E_OK;
                                state        <= T_DONE;
                            end else begin
                                b1  <= cur;
                                ptr <= ptr + 10'd1;
                                psub <= P_CN2;
                            end
                        end

                        //--------------------------------------------------
                        // UTF-8 第 3 字节 → 算出 Unicode 码点 → 开始查表
                        //--------------------------------------------------
                        P_CN2: begin
                            if ((cur & 8'hC0) != 8'h80) begin
                                scan_done    <= 1'b1;
                                txt_err_code <= (char_cnt == 0) ? E_NO_TEXT : E_OK;
                                state        <= T_DONE;
                            end else begin
                                // 码点 = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
                                cp      <= {(b0 & 8'h0F), 12'b0} |
                                           {2'b0, (b1 & 8'h3F), 6'b0} |
                                           {10'b0, (cur & 8'h3F)};
                                ptr      <= ptr + 10'd1;
                                lk_addr  <= 10'd0;
                                lk_start <= 1'b1;      // 进查表状态后先空转 1 拍
                                lk_run   <= 1'b0;
                                psub     <= P_LOOKUP;
                            end
                        end

                        //--------------------------------------------------
                        // 线性查表：在 745 条码点里找 cp
                        //   表里有这个字  → 索引 = 96 + 位置
                        //   表里没有这个字→ 索引 = 0（显示成空白）
                        //   最多 746 拍就查完了，只在开机时做一次，不心疼
                        //
                        // ★ 流水线对齐（这里曾经写错过，导致所有汉字偏后一个字）
                        //   ROM 读延迟 1 拍：cmap_code@t = mem[lk_addr@(t-1)]
                        //   而 lk_addr_q1@t 正好 = lk_addr@(t-1)
                        //   → 当拍 cmap_code 与 当拍 lk_addr_q1 天然对齐，直接比即可。
                        //   只留第 1 拍空转（此时 ROM 吐的是上一轮查表的残留数据）。
                        //--------------------------------------------------
                        P_LOOKUP: begin
                            // 每拍把当前地址打一拍，用来跟 cmap_code 同拍对齐
                            lk_addr_q1 <= lk_addr;

                            if (lk_start) begin
                                // 第 1 拍：ROM 还没吐出有效数据，只把地址 0 送出去
                                lk_addr  <= 10'd0;
                                lk_start <= 1'b0;
                                lk_run   <= 1'b1;
                            end else if (lk_run) begin
                                // 第 2 拍起：cmap_code 与 lk_addr_q1 严格同拍
                                if (cmap_code == cp) begin
                                    // ★ 命中：索引 = 96 + 条目序号（最大 840，10 位够用）
                                    emit_idx <= IDX_CN_BASE + lk_addr_q1;
                                    psub     <= P_EMIT;
                                end else if (lk_addr_q1 >= CN_LAST) begin
                                    // 查到底也没找到 → 空白
                                    emit_idx <= 10'd0;
                                    psub     <= P_EMIT;
                                end else begin
                                    lk_addr <= lk_addr + 10'd1;
                                end
                            end
                        end

                        //--------------------------------------------------
                        // 把索引摆上总线，翻转请求
                        //--------------------------------------------------
                        P_EMIT: begin
                            O_idx     <= emit_idx;
                            O_req_tgl <= ~O_req_tgl;
                            psub      <= P_WAIT;
                        end

                        //--------------------------------------------------
                        // 等对端应答追上来（期间数据保持不动，跨域安全）
                        //--------------------------------------------------
                        P_WAIT: begin
                            if (ack_sync[1] == O_req_tgl) begin
                                char_cnt <= char_cnt + 10'd1;
                                psub     <= P_FETCH;
                            end
                        end

                        default: psub <= P_FETCH;
                    endcase
                end

                //==========================================================
                //  全部完成，保持不动
                //==========================================================
                T_DONE: begin
                    sd_sec_read <= 1'b0;
                    scan_done   <= 1'b1;
                end

                //==========================================================
                //  出错（没找到文件）：画面照常，只是没有字幕
                //==========================================================
                T_ERR: begin
                    sd_sec_read <= 1'b0;
                    scan_done   <= 1'b1;
                    if (scan_start) begin
                        scan_sector  <= 32'd0;
                        buf_cnt      <= 10'd0;
                        char_cnt     <= 10'd0;
                        scan_done    <= 1'b0;
                        scan_found   <= 1'b0;
                        txt_err_code <= E_OK;
                        state        <= T_BPB;
                    end
                end

                default: state <= T_IDLE;
            endcase
        end
    end

endmodule
