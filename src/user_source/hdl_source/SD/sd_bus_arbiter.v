//==============================================================================
//  文件名  : sd_bus_arbiter.v
//  模块名  : sd_bus_arbiter
//  功能    : SD 卡（SPI）总线仲裁器 —— 让"读图片"和"读音乐"共用一条总线
//------------------------------------------------------------------------------
//  【为什么需要仲裁】
//  板子上只有一条 SD 卡 SPI 总线（4 根线），而我们的系统要同时做三件事：
//     ① 读 BMP 图片   （sd_card_bmp，每张 900KB，切图时突发读取）
//     ② 读 WAV 音乐   （wav_read，持续 192KB/s，必须不间断）
//     ③ 读 TXT 字幕   （txt_read，只在开机时读一次，几百字节，很快读完）
//  两个模块都要用同一条总线，所以需要一个"交通警察"来分配使用权。
//
//  【为什么仲裁粒度是"一个扇区"】
//  SD 卡的读命令（CMD17）一旦发出，就必须把整个 512 字节扇区读完，
//  中途无法暂停。所以仲裁只能在一个扇区读完之后切换，不能更细。
//
//  【仲裁策略】
//    音频优先，但要给图片留出足够的连续带宽：
//      · 音频 FIFO 水位很低（快放完了）→ 音频立刻抢占总线，防止断音
//      · 否则字幕优先             → 字幕只在开机读 1~2 个扇区，让它赶紧读完
//      · 否则图片优先             → 图片数据量大，连续读吞吐更高
//      · 音频 FIFO 还有空间时也给它补一点 → 防止音频长期被饿死
//
//    ★ 字幕为什么排在音频"告急"之后、图片之前？
//      字幕只在开机时读 1~2 个扇区（约 400µs），读完就再也不占总线了。
//      让它插在图片前面，可以保证"开机后立刻有字幕"，而且代价极小。
//      但它不能抢在"音频告急"前面，否则极端情况下会断音。
//
//    带宽核算（写进设计文档，答辩会问）：
//      音频需求   : 48000 帧/s × 4 字节 = 192 KB/s = 375 扇区/s
//      单扇区耗时 : 512×8 / 25MHz ≈ 164µs + CMD17 开销 ≈ 184µs
//      音频占用率 : 375 × 184µs ≈ 6.9%   ← 只占不到 7% 的总线时间
//      一张图片   : 900KB / 512B = 1758 个扇区 ≈ 324ms
//      结论       : 总线带宽绰绰有余，音频插队对图片影响很小
//
//  【★ 最容易出错的地方：数据必须"按通道门控"】
//    sd_card_top 读出的数据是广播的（两个通道都能看到）。
//    但 bmp_read 内部有一个字节计数器，它对"每一个 data_valid"都加 1。
//    如果把音频扇区的数据也让它看到，计数器就会多算 512，
//    导致图片数据错位 → 花屏/黑屏。
//    所以必须用 grant_sel 把 data_valid 和 end 严格分发给被授权的通道。
//    —— 这是整个音频改造中风险最高的一处，务必保留这段注释。
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一改造）
//==============================================================================

module sd_bus_arbiter #(
    // 音频 FIFO 水位门限（单位：个采样帧，每帧 4 字节，16bit 立体声）
    //
    // ★【重要】水位上限必须考虑"一次授权会灌入多少数据"！
    //   FIFO 深度 512 帧。协商粒度是"一个扇区"= 512 字节 = 128 帧。
    //   如果上限设成 448（曾经就是这么写的），那么：
    //        水位 448 时授权 → 再灌 128 帧 → 576 帧 > 512 → 溢出！
    //   溢出的后果：音频数据丢失/错乱 → 听到"滋滋"噪音。
    //
    //   正确算法：MAX_WM ≤ FIFO深度 - 一次突发量 = 512 - 128 = 384
    //   这里取 320，留 64 帧余量。
    //
    //   现象对照：不放图片时音频独占总线、水位一直很低，所以正常；
    //             一旦图片开始读，水位被饿到高位，再授权就溢出 → 噪音。
    parameter [8:0] WAV_LOW_WM = 9'd128,   // 低于此 → 音频告急，抢占总线
    parameter [8:0] WAV_MAX_WM = 9'd320    // 高于此 → 音频退让，防止溢出
)(
    input  wire        clk,               // sd_card_clk = 100MHz
    input  wire        rst,               // 高有效复位

    // ---------------- 面向 sd_card_top（唯一的主设备）----------------
    output reg         sd_sec_read,       // 请求读一个扇区
    output reg  [31:0] sd_sec_read_addr,  // 扇区地址（授权时锁存，全程保持稳定）
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,

    // ---------------- BMP 通道（接 sd_card_bmp）----------------
    input  wire        bmp_sec_read,
    input  wire [31:0] bmp_sec_read_addr,
    output wire [7:0]  bmp_sec_read_data,
    output wire        bmp_sec_read_data_valid,
    output wire        bmp_sec_read_end,

    // ---------------- WAV 通道（接 wav_read）----------------
    input  wire        wav_sec_read,
    input  wire [31:0] wav_sec_read_addr,
    output wire [7:0]  wav_sec_read_data,
    output wire        wav_sec_read_data_valid,
    output wire        wav_sec_read_end,

    // ---------------- TXT 通道（接 txt_read）----------------
    input  wire        txt_sec_read,
    input  wire [31:0] txt_sec_read_addr,
    output wire [7:0]  txt_sec_read_data,
    output wire        txt_sec_read_data_valid,
    output wire        txt_sec_read_end,

    // ---------------- 音频 FIFO 水位（写侧时钟域，即本时钟域）----------------
    input  wire [8:0]  wav_fifo_wrusedw,

    // ---------------- WAV 是否已经完成扫描 ----------------
    //  ★【重要】WAV 扫描期间 FIFO 是空的，如果不加这个门控，
    //    扫描会被当成"音频告急"，从而长期霸占总线，
    //    把图片装载活活饿死（现象：换图时黑屏卡好几秒）。
    //    扫描阶段根本不需要音频数据，所以这时候不许它"告急"。
    input  wire        wav_scan_done,

    // ---------------- 调试输出 ----------------
    output wire        O_grant_bmp,       // 当前授权给图片
    output wire        O_grant_wav,       // 当前授权给音频
    output wire        O_grant_txt        // 当前授权给字幕
);

    //--------------------------------------------------------------------------
    // 通道编码
    //--------------------------------------------------------------------------
    localparam [1:0] SEL_NONE = 2'd0;
    localparam [1:0] SEL_BMP  = 2'd1;
    localparam [1:0] SEL_WAV  = 2'd2;
    localparam [1:0] SEL_TXT  = 2'd3;

    // 仲裁状态机
    localparam [1:0] A_IDLE     = 2'd0;   // 空闲，可以接受新请求
    localparam [1:0] A_ACTIVE   = 2'd1;   // 正在读一个扇区
    localparam [1:0] A_COOLDOWN = 2'd2;   // 空转一拍，防止控制器"回马枪"

    reg [1:0] grant_sel;      // 当前授权给哪个通道
    reg [1:0] a_state;

    //==========================================================================
    //  第 1 部分：优先级判断（组合逻辑）
    //==========================================================================
    // 音频"告急"：FIFO 水位低于低水位线 → 再不读就要断音了
    //   ★ 必须加 wav_scan_done 门控：
    //     扫描期间 FIFO 天然是空的，会让 wav_urgent 恒为 1，
    //     于是扫描霸占总线 → 图片装载被饿死 → 换图时黑屏卡住。
    wire wav_urgent = wav_sec_read & wav_scan_done & (wav_fifo_wrusedw <= WAV_LOW_WM);

    // 音频"还想再要点"：FIFO 还没满 → 可以在空闲时补一点
    wire wav_ok     = wav_sec_read & (wav_fifo_wrusedw <  WAV_MAX_WM);

    reg [1:0] pick;
    always @(*) begin
        if (wav_urgent)
            pick = SEL_WAV;        // ① 音频告急 → 绝对优先（保证不断音）
        else if (bmp_sec_read)
            pick = SEL_BMP;        // ② 图片优先（数据量大，绝不能被饿死）
        else if (txt_sec_read)
            pick = SEL_TXT;        // ③ 图片没需求时再扫字幕（按簇扫，0.2 秒就完）
        else if (wav_ok)
            pick = SEL_WAV;        // ④ 都没需求，音频有空间 → 给音频补
        else
            pick = SEL_NONE;
    end

    //==========================================================================
    //  第 2 部分：仲裁状态机
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_state          <= A_IDLE;
            grant_sel        <= SEL_NONE;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
        end else begin
            case (a_state)

                //----------------------------------------------------------
                A_IDLE: begin
                    if (pick == SEL_BMP) begin
                        grant_sel        <= SEL_BMP;
                        sd_sec_read_addr <= bmp_sec_read_addr;   // 锁存地址，全程稳定
                        sd_sec_read      <= 1'b1;
                        a_state          <= A_ACTIVE;
                    end else if (pick == SEL_WAV) begin
                        grant_sel        <= SEL_WAV;
                        sd_sec_read_addr <= wav_sec_read_addr;
                        sd_sec_read      <= 1'b1;
                        a_state          <= A_ACTIVE;
                    end else if (pick == SEL_TXT) begin
                        grant_sel        <= SEL_TXT;
                        sd_sec_read_addr <= txt_sec_read_addr;
                        sd_sec_read      <= 1'b1;
                        a_state          <= A_ACTIVE;
                    end
                end

                //----------------------------------------------------------
                A_ACTIVE: begin
                    if (sd_sec_read_end) begin
                        // ★ 必须在本拍就把 sd_sec_read 撤下来！
                        //   否则 sd_card_sec_read_write 回到空闲状态后
                        //   会立刻重启一次读，读出一个没人要的扇区。
                        sd_sec_read <= 1'b0;
                        a_state     <= A_COOLDOWN;
                    end
                end

                //----------------------------------------------------------
                A_COOLDOWN: begin
                    a_state <= A_IDLE;      // 空转一拍，让总线稳定
                end

                default: a_state <= A_IDLE;
            endcase
        end
    end

    //==========================================================================
    //  第 3 部分：数据分发（★ 必须严格按 grant_sel 门控，否则图片会花屏）
    //==========================================================================
    // 数据字节可以共享（它只是个值，不会引起副作用）
    assign bmp_sec_read_data = sd_sec_read_data;
    assign wav_sec_read_data = sd_sec_read_data;
    assign txt_sec_read_data = sd_sec_read_data;

    // 但 data_valid 和 end 必须门控！
    //   bmp_read 会对每个 data_valid 累加字节计数，
    //   如果混入音频扇区的数据，图片数据就会错位。
    assign bmp_sec_read_data_valid = sd_sec_read_data_valid & (grant_sel == SEL_BMP);
    assign bmp_sec_read_end        = sd_sec_read_end        & (grant_sel == SEL_BMP);

    assign wav_sec_read_data_valid = sd_sec_read_data_valid & (grant_sel == SEL_WAV);
    assign wav_sec_read_end        = sd_sec_read_end        & (grant_sel == SEL_WAV);

    assign txt_sec_read_data_valid = sd_sec_read_data_valid & (grant_sel == SEL_TXT);
    assign txt_sec_read_end        = sd_sec_read_end        & (grant_sel == SEL_TXT);

    //==========================================================================
    //  第 4 部分：调试输出
    //==========================================================================
    assign O_grant_bmp = (grant_sel == SEL_BMP);
    assign O_grant_wav = (grant_sel == SEL_WAV);
    assign O_grant_txt = (grant_sel == SEL_TXT);

endmodule
