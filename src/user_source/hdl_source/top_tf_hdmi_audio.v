
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 按键 KEY_3（引脚 B1）切图 / 切换调节项
    input                       key2,           // 按键 KEY_4（引脚 C1）周期+ / 参数+
    input                       key3,           // ★【新增】按键 KEY_2（引脚 B2）减键

    // ---- ★【新增】4 个拨码开关（引脚从 HX4S20C 原理图查得）----
    //   SW1 → C8 ：工作模式 / 调节模式
    //   SW2 → C7 ：自动轮播 / 固定
    //   SW3 → C6 ：淡入淡出转场 / 硬切
    //   SW4 → C5 ：显示 OSD / 隐藏 OSD
    input                       sw1,
    input                       sw2,
    input                       sw3,
    input                       sw4,

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;      // 音频 PLL 输出的 12.288MHz
// ★【改造】原 I2S 测试音相关信号(audio_i2s_bclk/lrck/dout)和
//   解串后的 audio_valid/audio_left_data/audio_right_data 已全部删除。
//   音频数据现在来自 TF 卡（见下方"音频子系统"）。
//   注意：audio_mclk 虽然不再参与音频通路，但仍需保留一个"消费者"，
//   否则综合工具会把这个 PLL 优化掉，进而让 audio_pll_lock 变成常量、
//   影响 rst_all 复位逻辑（见下面的 audio_clk_alive 计数器）。
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire rst_all;
assign rst_all = ~rst_n | ~audio_pll_lock;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

//--------------------------------------------------------------------------
// ★ 音频 PLL 的"存活负载"
//   audio_mclk 现在不参与音频通路了，如果没有任何负载，
//   综合工具会认为这个 PLL 没用而把它优化掉，
//   那样 audio_pll_lock 就变成常量，rst_all 的复位逻辑会失效。
//   这里放一个最简计数器当"消费者"，代价很小，但能保住 PLL 正常工作。
//   计数器的最高位同时可以当"音频 PLL 已锁定"的指示灯用。
//--------------------------------------------------------------------------
reg [15:0] audio_clk_alive;

always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all)
        audio_clk_alive <= 16'd0;
    else
        audio_clk_alive <= audio_clk_alive + 16'd1;
end

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// =========================================================================
//  人机交互子系统（★ 拨码开关版）
// -------------------------------------------------------------------------
//  4 个拨码开关 + 2 个按键。完整操作表见 common/key_ctrl_fsm.v 文件头注释。
//
//  拨码开关引脚（从 HX4S20C 原理图查得）：
//      SW1 → C8（工作/调节模式）   SW2 → C7（自动轮播/固定）
//      SW3 → C6（转场开关）        SW4 → C5（OSD 开关）
//
//  这个模块工作在 50MHz 的 clk 域，是本系统的"人机交互大脑"。
// =========================================================================

//--------------------------------------------------------------------------
// 拨码开关输入同步（2 级触发器防亚稳态）
//   拨码开关是机械触点，拨动瞬间会有抖动。
//   但开关只决定"模式"、不产生事件，即使抖动导致状态瞬间跳变，
//   用户也看不出来，所以只做 2 级同步即可，不需要 20ms 消抖计数器。
//--------------------------------------------------------------------------
reg sw1_sync0, sw1_sync1;
reg sw2_sync0, sw2_sync1;
reg sw3_sync0, sw3_sync1;
reg sw4_sync0, sw4_sync1;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        sw1_sync0 <= 1'b0;  sw1_sync1 <= 1'b0;
        sw2_sync0 <= 1'b0;  sw2_sync1 <= 1'b0;
        sw3_sync0 <= 1'b0;  sw3_sync1 <= 1'b0;
        sw4_sync0 <= 1'b0;  sw4_sync1 <= 1'b0;
    end else begin
        sw1_sync0 <= sw1;   sw1_sync1 <= sw1_sync0;
        sw2_sync0 <= sw2;   sw2_sync1 <= sw2_sync0;
        sw3_sync0 <= sw3;   sw3_sync1 <= sw3_sync0;
        sw4_sync0 <= sw4;   sw4_sync1 <= sw4_sync0;
    end
end

wire [7:0] cfg_period_sec;      // 轮播周期（秒）  → 送 sd_card_clk 域
wire [4:0] cfg_brightness;      // 亮度 0..31      → 送 video_clk 域
wire [4:0] cfg_contrast;        // 对比度 0..31    → 送 video_clk 域
wire       cfg_adj_mode;        // 运行/调节模式   → 送 video_clk 域
wire [1:0] cfg_adj_sel;         // 当前调节项      → 送 video_clk 域
wire       cfg_music_en;        // 音乐开关(SW3)   → 送 video_clk 域
wire       cfg_osd_en;          // OSD 使能        → 送 video_clk 域
wire       cfg_auto_play;       // 自动轮播开关    → 送 sd_card_clk 域
wire       key_next_pulse;      // 手动切下一张（单拍脉冲）

key_ctrl_fsm #(
    .CLK_FREQ_HZ    (50_000_000),
    .SW_ACTIVE_HIGH (1'b1)      // ★ 拨码开关有效电平：拨到 ON 时读高（若方向反了改这里）
) u_key_ctrl_fsm (
    .clk              (clk),
    .rst              (rst_all),
    .key1             (key1),
    .key2             (key2),
    .key3             (key3),           // ★ 新增：KEY_2（B2）减键
    .sw_mode          (sw1_sync1),
    .sw_auto          (sw2_sync1),
    .sw_music         (sw3_sync1),
    .sw_osd           (sw4_sync1),
    .O_period_sec     (cfg_period_sec),
    .O_brightness     (cfg_brightness),
    .O_contrast       (cfg_contrast),
    .O_adj_sel        (cfg_adj_sel),
    .O_key_next_pulse (key_next_pulse),
    .O_adj_mode       (cfg_adj_mode),
    .O_auto_play      (cfg_auto_play),
    .O_music_en       (cfg_music_en),
    .O_osd_en         (cfg_osd_en)
);

//--------------------------------------------------------------------------
//  跨时钟域传输配置参数（原理见 common/cfg_cdc.v 的详细注释）
//    ① cfg_period_sec  → sd_card_clk 域，给 sd_card_bmp 决定轮播周期
//    ② 视频相关配置    → video_clk 域，给图像处理流水线 / OSD
//
//  ★ 视频域配置打包成一个 16bit 字一次性跨域，比逐个信号跨域简单可靠得多
//--------------------------------------------------------------------------
wire [7:0] cfg_period_sec_sd;

cfg_cdc #(
    .WIDTH (8)
) u_cdc_period (
    .I_clk_src (clk),
    .I_rst_src (rst_all),
    .I_data    (cfg_period_sec),
    .I_clk_dst (sd_card_clk),
    .I_rst_dst (rst_all),
    .O_data    (cfg_period_sec_sd)
);

// 视频域配置字段分配：
//   [15:11] 亮度   [10:6] 对比度   [5] 运行/调节模式
//   [4:3]   调节项 [2]    音乐开关 [1] OSD 开关   [0] 预留
wire [15:0] cfg_video_src = {
    cfg_brightness,      // [15:11]
    cfg_contrast,        // [10:6]
    cfg_adj_mode,        // [5]
    cfg_adj_sel,         // [4:3]
    cfg_music_en,        // [2]   音乐开关（SW3）
    cfg_osd_en,          // [1]   OSD 开关（SW4）
    1'b0                 // [0]   预留
};

wire [15:0] cfg_video;

cfg_cdc #(
    .WIDTH (16)
) u_cdc_video (
    .I_clk_src (clk),
    .I_rst_src (rst_all),
    .I_data    (cfg_video_src),
    .I_clk_dst (video_clk),
    .I_rst_dst (rst_all),
    .O_data    (cfg_video)
);

wire [4:0] vcfg_brightness = cfg_video[15:11];
wire [4:0] vcfg_contrast   = cfg_video[10:6];
wire       vcfg_adj_mode   = cfg_video[5];
wire [1:0] vcfg_adj_sel    = cfg_video[4:3];
wire       vcfg_music_en   = cfg_video[2];   // 音乐开关（SW3）
wire       vcfg_osd_en     = cfg_video[1];   // OSD 开关

//--------------------------------------------------------------------------
// 轮播周期数值也要送到 video_clk 域 —— 给 OSD 显示"周期 05秒"用
//   （period_sec 本来只送到 sd_card_clk 域给 sd_card_bmp，OSD 还需要一份）
//--------------------------------------------------------------------------
wire [7:0] cfg_period_sec_v;

cfg_cdc #(
    .WIDTH (8)
) u_cdc_period_v (
    .I_clk_src (clk),
    .I_rst_src (rst_all),
    .I_data    (cfg_period_sec),
    .I_clk_dst (video_clk),
    .I_rst_dst (rst_all),
    .O_data    (cfg_period_sec_v)
);

//--------------------------------------------------------------------------
// 自动轮播开关（SW2）也要跨到 sd_card_clk(100MHz) 域，给 sd_card_bmp 用
//   1bit 电平信号，用 cfg_cdc 的 toggle 握手方式跨域最稳妥
//--------------------------------------------------------------------------
wire cfg_auto_play_sd;

cfg_cdc #(
    .WIDTH (1)
) u_cdc_auto (
    .I_clk_src (clk),
    .I_rst_src (rst_all),
    .I_data    (cfg_auto_play),
    .I_clk_dst (sd_card_clk),
    .I_rst_dst (rst_all),
    .O_data    (cfg_auto_play_sd)
);

// =========================================================================
//  ★【重要】音频子系统相关的线网必须先在这里声明！
// -------------------------------------------------------------------------
//  Verilog 有个坑：信号如果在"使用之后"才声明，工具会先给它建一个
//  1 位宽的"隐式线网"，后面真正的 32 位声明就会冲突（HDL-7225 严重警告），
//  结果是地址/数据线连接被截断成 1 位，功能完全失效。
//  所以下面这些线网必须写在 sd_card_bmp 例化之前。
// =========================================================================

// ---- 面向 sd_card_top 的总线（仲裁器输出）----
wire        sd_bus_sec_read;
wire [31:0] sd_bus_sec_read_addr;
wire [7:0]  sd_bus_sec_read_data;
wire        sd_bus_sec_read_dv;
wire        sd_bus_sec_read_end;
wire        sd_init_done_bus;        // SD 卡初始化完成

// ---- BMP 通道线（仲裁器 <-> sd_card_bmp）----
wire        bmp_sd_sec_read;
wire [31:0] bmp_sd_sec_read_addr;
wire [7:0]  bmp_sd_sec_read_data;
wire        bmp_sd_sec_read_dv;
wire        bmp_sd_sec_read_end;

// ---- WAV 通道线（仲裁器 <-> wav_read）----
wire        wav_sd_sec_read;
wire [31:0] wav_sd_sec_read_addr;
wire [7:0]  wav_sd_sec_read_data;
wire        wav_sd_sec_read_dv;
wire        wav_sd_sec_read_end;

// ---- TXT 字幕通道（第 3 个 SD 总线用户）----
wire        txt_sd_sec_read;
wire [31:0] txt_sd_sec_read_addr;
wire [7:0]  txt_sd_sec_read_data;
wire        txt_sd_sec_read_dv;
wire        txt_sd_sec_read_end;

// ---- 字幕跨时钟域握手（sd_card_clk 100MHz → video_clk 25MHz）----
wire [9:0]  txt_idx;          // 字库索引
wire        txt_req_tgl;      // 请求翻转
wire        txt_ack_tgl;      // 应答翻转
wire        txt_scan_done;
wire        txt_scan_found;
wire [2:0]  txt_err_code;
wire [3:0]  txt_state_code;

// ---- 音频 FIFO 线 ----
wire [31:0] audio_fifo_dout;
wire        audio_fifo_empty;
wire        audio_fifo_full;
wire [8:0]  audio_fifo_wrusedw;   // 512 深 → 水位计数 9 位
wire        audio_fifo_re;

// ===================== TF 多图扫描与缓存（双缓冲） =====================
// 新增的状态输出线（供 OSD / 转场使用）
wire        load_busy_sd;         // 正在装载新图
wire        auto_play_en_sd;      // 自动轮播开关状态
wire [2:0]  img_idx_sd;           // 当前第几张（★ 2→3 位，支持更多图）
wire [2:0]  img_found_count_sd;   // 共几张

sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    // ★ 注意：这里接的是按键子系统出来的"单拍脉冲"，
    //   不能接原始按键电平（sd_card_bmp 内部的消抖已删除）
    .key_next          (key_next_pulse),
    .auto_play_ext     (cfg_auto_play_sd),    // ★ 自动轮播开关（拨码开关 SW2，电平信号）
    .I_period_sec      (cfg_period_sec_sd),   // ★ 轮播周期（可配置）
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    // ★ 新增状态输出
    .O_load_busy       (load_busy_sd),
    .O_auto_play_en    (auto_play_en_sd),
    .O_img_idx         (img_idx_sd),
    .O_img_found_count (img_found_count_sd),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),

    // ★【改造】SD 总线改为从顶层接入（图片和音频共用，由仲裁器分配）
    .sd_init_done           (sd_init_done_bus),
    .sd_sec_read            (bmp_sd_sec_read),
    .sd_sec_read_addr       (bmp_sd_sec_read_addr),
    .sd_sec_read_data       (bmp_sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_sd_sec_read_dv),
    .sd_sec_read_end        (bmp_sd_sec_read_end)
);

// =========================================================================
//  ★【新增】音频子系统：从 TF 卡读 WAV 音乐，经 HDMI 输出
// -------------------------------------------------------------------------
//  数据流：
//
//     TF卡 ── sd_card_top（唯一实例，提到顶层）
//                   │
//              sd_bus_arbiter（扇区级仲裁，音频优先）
//                   │
//          ┌────────┴────────┐
//      BMP通道             WAV通道
//          │                 │
//    sd_card_bmp         wav_read（扫描+解析+流式PCM）
//    （读图片，原有）            │
//                         音频FIFO（100MHz写 / 25MHz读）
//                              │
//                         audio_player（48kHz节拍）
//                              │
//                        HDMI 1.4b 发射核音频口
//
//  原本的"内部方波测试音"(hdmi_audio_tone_i2s_64fs + I2S_receiver)已移除 ——
//  这也是合规要求："音频处理方法不能和参考例程相同"。
// =========================================================================

// ---- SD 卡控制器（唯一实例）----
//  注意：sd_bus_* / bmp_sd_* / wav_sd_* / audio_fifo_* / sd_init_done_bus
//        这些线网已经提到前面（sd_card_bmp 例化之前）统一声明了，
//        这里不再重复声明 —— 重复声明会与"隐式线网"冲突（HDL-7225）。

sd_card_top #(
    .SPI_LOW_SPEED_DIV  (248),
    .SPI_HIGH_SPEED_DIV (0)          // 0 → 25MHz；某些卡不稳时可改 2 (12.5MHz)
) u_sd_card_top (
    .clk                    (sd_card_clk),
    .rst                    (rst_all),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
    .sd_init_done           (sd_init_done_bus),
    .sd_sec_read            (sd_bus_sec_read),
    .sd_sec_read_addr       (sd_bus_sec_read_addr),
    .sd_sec_read_data       (sd_bus_sec_read_data),
    .sd_sec_read_data_valid (sd_bus_sec_read_dv),
    .sd_sec_read_end        (sd_bus_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

// =========================================================================
//  WAV 扫描启动脉冲（★ 关键：等图片显示出来之后才开始扫音乐）
// -------------------------------------------------------------------------
//  【为什么不能一上电就扫音乐】
//    仲裁器的策略是"音频 FIFO 快空了就绝对优先"（防止断音）。
//    而"扫描阶段"音频 FIFO 必然是空的（还没读到数据），
//    于是 wav_urgent 恒为 1 —— 音频会死死占住 SD 总线，
//    图片扫描一点总线都拿不到，导致【开机后好几秒才出图】。
//
//    所以这里把启动条件从 "SD 初始化完成" 改成 "首图已显示(display_valid)"：
//      阶段1：图片扫描独占总线 → 快速扫描 + 加载首图 → 屏幕很快出画面
//      阶段2：画面稳定后，音乐扫描才开始 → 再过几秒音乐响起
//
//    副作用：音乐比画面晚几秒响起。对广告牌来说这是可接受的
//            （先看到广告，再有背景音乐，观感反而更自然）。
// =========================================================================
reg  [21:0] wav_scan_dly;
reg         wav_scan_start;

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        wav_scan_dly   <= 22'd0;
        wav_scan_start <= 1'b0;
    end else begin
        wav_scan_start <= 1'b0;
        // ★ 触发条件：SD 初始化完成 且 第一张图片已经显示出来
        if (sd_init_done_bus && display_valid) begin
            if (wav_scan_dly < 22'h3F_FFFF)
                wav_scan_dly <= wav_scan_dly + 22'd1;
            else if (wav_scan_dly == 22'h3F_FFFF) begin
                wav_scan_start <= 1'b1;         // 单拍脉冲，启动 WAV 扫描
                wav_scan_dly   <= 22'h3F_FFFF + 22'd1;
            end
        end
    end
end

// =========================================================================
//  TXT 字幕扫描启动脉冲
// -------------------------------------------------------------------------
//  字幕文件很小（1~2 个扇区），而且在仲裁器里排在图片之前，
//  所以不需要像 WAV 那样延迟启动 —— 画面一出来就可以扫。
//  扫完之后 txt_read 就再也不请求总线了，对图片/音频零影响。
// =========================================================================
reg  [21:0] txt_scan_dly;
reg         txt_scan_start;

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        txt_scan_dly   <= 22'd0;
        txt_scan_start <= 1'b0;
    end else begin
        txt_scan_start <= 1'b0;
        if (sd_init_done_bus && display_valid) begin
            if (txt_scan_dly < 22'h0F_FFFF)
                txt_scan_dly <= txt_scan_dly + 22'd1;
            else if (txt_scan_dly == 22'h0F_FFFF) begin
                txt_scan_start <= 1'b1;         // 单拍脉冲，启动字幕扫描
                txt_scan_dly   <= 22'h0F_FFFF + 22'd1;
            end
        end
    end
end

// ---- TXT 字幕读取模块 ----
txt_read u_txt_read (
    .clk                    (sd_card_clk),
    .rst                    (rst_all),
    .scan_start             (txt_scan_start),
    .scan_max_sector        (32'd131071),
    .scan_done              (txt_scan_done),
    .scan_found             (txt_scan_found),
    .txt_err_code           (txt_err_code),
    .sd_sec_read            (txt_sd_sec_read),
    .sd_sec_read_addr       (txt_sd_sec_read_addr),
    .sd_sec_read_data       (txt_sd_sec_read_data),
    .sd_sec_read_data_valid (txt_sd_sec_read_dv),
    .sd_sec_read_end        (txt_sd_sec_read_end),
    .O_idx                  (txt_idx),
    .O_req_tgl              (txt_req_tgl),
    .I_ack_tgl              (txt_ack_tgl),
    .state_code             (txt_state_code)
);

// ---- WAV 扫描/读取模块 ----
wire        wav_scan_done;
wire        wav_scan_found;
wire [31:0] wav_found_sector;
wire [3:0]  wav_err_code;
wire [3:0]  wav_state_code;
wire        wav_pcm_wr_en;
wire [31:0] wav_pcm_data;

wav_read #(
    .START_SECTOR (32'd0)
) u_wav_read (
    .clk                    (sd_card_clk),
    .rst                    (rst_all),
    .scan_start             (wav_scan_start),
    .scan_max_sector        (32'd131071),
    .scan_done              (wav_scan_done),
    .scan_found             (wav_scan_found),
    .scan_found_sector      (wav_found_sector),
    .wav_err_code           (wav_err_code),
    .play_en                (1'b1),              // 找到后持续播放（数据读完自动循环）
    .sd_sec_read            (wav_sd_sec_read),
    .sd_sec_read_addr       (wav_sd_sec_read_addr),
    .sd_sec_read_data       (wav_sd_sec_read_data),
    .sd_sec_read_data_valid (wav_sd_sec_read_dv),
    .sd_sec_read_end        (wav_sd_sec_read_end),
    .pcm_wr_en              (wav_pcm_wr_en),
    .pcm_data               (wav_pcm_data),
    .I_fifo_full            (audio_fifo_full),   // ★ 保险：FIFO 满时 wav_read 丢帧不写
    .state_code             (wav_state_code)
);

// ---- SD 总线仲裁器 ----
sd_bus_arbiter u_sd_bus_arbiter (
    .clk                     (sd_card_clk),
    .rst                     (rst_all),
    .sd_sec_read             (sd_bus_sec_read),
    .sd_sec_read_addr        (sd_bus_sec_read_addr),
    .sd_sec_read_data        (sd_bus_sec_read_data),
    .sd_sec_read_data_valid  (sd_bus_sec_read_dv),
    .sd_sec_read_end         (sd_bus_sec_read_end),
    .bmp_sec_read            (bmp_sd_sec_read),
    .bmp_sec_read_addr       (bmp_sd_sec_read_addr),
    .bmp_sec_read_data       (bmp_sd_sec_read_data),
    .bmp_sec_read_data_valid (bmp_sd_sec_read_dv),
    .bmp_sec_read_end        (bmp_sd_sec_read_end),
    .wav_sec_read            (wav_sd_sec_read),
    .wav_sec_read_addr       (wav_sd_sec_read_addr),
    .wav_sec_read_data       (wav_sd_sec_read_data),
    .wav_sec_read_data_valid (wav_sd_sec_read_dv),
    .wav_sec_read_end        (wav_sd_sec_read_end),
    .txt_sec_read            (txt_sd_sec_read),
    .txt_sec_read_addr       (txt_sd_sec_read_addr),
    .txt_sec_read_data       (txt_sd_sec_read_data),
    .txt_sec_read_data_valid (txt_sd_sec_read_dv),
    .txt_sec_read_end        (txt_sd_sec_read_end),
    .wav_fifo_wrusedw        (audio_fifo_wrusedw),
    .wav_scan_done           (wav_scan_done),   // ★ 扫描期间不许音频"告急"，否则会饿死图片
    .O_grant_bmp             (),
    .O_grant_wav             (),
    .O_grant_txt             ()
);

// ---- 音频异步 FIFO ----
//   直接复用工程里已有的 512 深 x 32bit 异步 FIFO（模块名 rfifo_32_32_512，
//   定义在 IP/afifo_32_16_256.v 里），不需要另外生成 IP。
//   写侧 sd_card_clk(100MHz)，读侧 video_clk(25MHz)，FWFT 语义。
rfifo_32_32_512 #(
    // ★ 关键参数：SHOW_AHEAD_EN = 1 打开"首字直通(FWFT)"模式
    //   该 IP 默认是 1'b0（非 FWFT）：那种模式下 dout 要等 re 拉高一拍后才有效。
    //   而 audio_player 是按 FWFT 语义写的（empty=0 时 dout 就是队首数据），
    //   所以这里必须显式打开，两边语义才匹配。
    .SHOW_AHEAD_EN (1'b1)
) u_audio_fifo (
    .rst        (rst_all),
    .clkw       (sd_card_clk),
    .clkr       (video_clk),
    .we         (wav_pcm_wr_en),
    .di         (wav_pcm_data),
    .re         (audio_fifo_re),
    .dout       (audio_fifo_dout),
    .valid      (),
    .full_flag  (audio_fifo_full),
    .empty_flag (audio_fifo_empty),
    .wrusedw    (audio_fifo_wrusedw),
    .rdusedw    ()
);

// ---- 音频播放器（video_clk 域）----
wire        aud_valid;
wire [23:0] aud_left;
wire [23:0] aud_right;
wire [15:0] aud_underrun;
wire [15:0] aud_frame_cnt;

// ★【新增】转场模块的线网，必须在"第一次被用到之前"先声明，
//   否则会被综合器当成隐式线网、截断成 1 位 → HDL-7225 警告 + 功能异常。
//   实际例化位置在下面 osd_adjust 之前，但这里 audio_player 就要用 fade_gain。
wire [7:0]  fade_gain;      // 转场时的背景音乐音量（128~255）
wire [1:0]  fade_state;     // 转场状态（调试用）
wire [23:0] vout_fade;      // 转场处理后的像素
wire        hs_fade, vs_fade, de_fade;

audio_player #(
    .CLK_FREQ_HZ    (25_000_000),
    .SAMPLE_RATE_HZ (48_000)
) u_audio_player (
    .video_clk          (video_clk),
    .rst                (rst_all),
    .I_fifo_dout        (audio_fifo_dout),
    .I_fifo_empty       (audio_fifo_empty),
    .O_fifo_re          (audio_fifo_re),
    .O_audio_valid      (aud_valid),
    .O_audio_left_data  (aud_left),
    .O_audio_right_data (aud_right),
    // ★【按用户要求】音量恒定，转场只影响画面，绝不碰音频。
    //   fade_ctrl 仍然输出 O_gain（音视频联动量），但这里故意不接 ——
    //   如果以后想拿"音视频联动"这个加分项，把下面改成 (fade_gain) 即可。
    .I_gain             (8'd255),           // 255 = 原音量，不衰减
    .O_underrun_cnt     (aud_underrun),
    .O_frame_cnt        (aud_frame_cnt)
);

// =========================================================================
//  数码管显示（★ 改造：由 seg_display 统一合成 6 位内容）
// -------------------------------------------------------------------------
//  显示版面见 SD/seg_display.v 的头部注释。这里只负责准备"要显示的数值"：
//      RUN 模式    → 显示当前轮播周期（秒）
//      ADJUST 模式 → 显示当前调节项的数值（亮度 / 对比度 / 周期）
//
//  ★ 注意：seg_scan 工作在 50MHz 的 clk 域，所以这里取用的配置参数
//    必须也是 clk 域的信号（cfg_* 而不是 vcfg_*），避免跨时钟域采样。
// =========================================================================
wire [15:0] seg_value = cfg_adj_mode
                      ? ((cfg_adj_sel == 2'd0) ? {11'd0, cfg_brightness} :
                         (cfg_adj_sel == 2'd1) ? {11'd0, cfg_contrast}   :
                                                  {8'd0,  cfg_period_sec})
                      : {8'd0, cfg_period_sec};

// auto_play_en 来自 sd_card_clk(100MHz) 域，这里打两拍同步到 clk 域再用
reg auto_play_sync0, auto_play_sync1;
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        auto_play_sync0 <= 1'b0;
        auto_play_sync1 <= 1'b0;
    end else begin
        auto_play_sync0 <= auto_play_en_sd;
        auto_play_sync1 <= auto_play_sync0;
    end
end

wire [7:0] seg_d0, seg_d1, seg_d2, seg_d3, seg_d4, seg_d5;

// ★ 字幕字符数要接给数码管调试用，必须**在使用之前**声明。
//   否则 TD 会按"隐式线网"处理成 1 位（HDL-7225），调试数字就全错了。
wire [9:0]  marq_text_len;

seg_display u_seg_display (
    .I_state_code (state_code),
    .I_adj_mode   (cfg_adj_mode),
    .I_adj_sel    (cfg_adj_sel),
    .I_auto_play  (auto_play_sync1),
    .I_value      (seg_value),
    // ---- 字幕调试（SW3 拨到 ON 时，数码管改显示字幕加载情况）----
    //   SW3 本来是留给"淡入淡出转场"的，那个功能还没做，先借来当调试开关。
    //   正常应显示：状态4 错误0 后三位是收到的字数
    // ★ 数码管字幕调试模式：SW3 已经改作"音乐开关"了，所以这里先关掉。
    //   想看字幕调试信息时，把下面这行改成 1'b1 重新编译即可
    //   （显示内容见 seg_display.v 的端口说明）。
    .I_debug      (1'b0),
    .I_txt_state  (txt_state_code),
    .I_txt_err    (txt_err_code),
    .I_txt_len    (marq_text_len),
    .O_seg_0      (seg_d0),
    .O_seg_1      (seg_d1),
    .O_seg_2      (seg_d2),
    .O_seg_3      (seg_d3),
    .O_seg_4      (seg_d4),
    .O_seg_5      (seg_d5)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        (seg_d0),
    .seg_data_1        (seg_d1),
    .seg_data_2        (seg_d2),
    .seg_data_3        (seg_d3),
    .seg_data_4        (seg_d4),
    .seg_data_5        (seg_d5)
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
wire [23:0] vout_base;
assign vout_base = display_valid ? vout_data_raw : 24'd0;

// =========================================================================
//  图像处理流水线（第 1 级）：亮度 / 对比度实时调节
// -------------------------------------------------------------------------
//  数据流：vout_base → [image_processor] → vout_proc → vout_data → AXIS → HDMI
//
//  ★ 关键：image_processor 内部把像素延迟 2 拍，同时把 hs/vs/de 也延迟 2 拍。
//    所以下游 video_rgb_to_axis_640x480 必须使用它输出的 de_proc / vs_proc，
//    绝不能再接原来的 de / vs —— 否则同步信号与像素错位，画面会偏移或撕裂。
//
//  阶段 1a：先用中性参数 (16/16)，此时输出应严格等于输入，
//           上板验证"画面与改造前逐像素一致"即说明流水线插入正确。
//  阶段 1b：改接按键状态机来的 cfg_brightness / cfg_contrast。
// =========================================================================
wire [23:0] vout_proc;
wire        hs_proc, vs_proc, de_proc;

image_processor u_image_processor (
    .video_clk    (video_clk),
    .rst          (rst_all),
    .I_de         (de),
    .I_hs         (hs),
    .I_vs         (vs),
    .I_rgb        (vout_base),
    .O_de         (de_proc),
    .O_hs         (hs_proc),
    .O_vs         (vs_proc),
    .O_rgb        (vout_proc),
    // ★ 参数来自按键子系统，经 cfg_cdc 跨到 video_clk 域
    //   中性值 16/16 时输出等于输入（画面不变）
    .I_brightness (vcfg_brightness),
    .I_contrast   (vcfg_contrast)
);

// =========================================================================
//  图像处理流水线（第 2 级）：OSD 调节界面
// -------------------------------------------------------------------------
//  只在"调节模式"（拨码 SW1 = ON）时，在屏幕左上角用绿色汉字+数字
//  显示当前正在调节的参数和数值；平时完全透明、不影响画面。
//
//  显示内容示例：
//      亮度   16
//      对比度 24
//      周期   05秒
//
//  数据流：vout_proc → [osd_adjust] → vout_osd → vout_data → AXIS → HDMI
//  ★ 本模块内部把像素和 hs/vs/de 都延迟 2 拍，所以下游必须用它输出的
//    de_osd / vs_osd，不能再用 de_proc / vs_proc。
// =========================================================================

// =========================================================================
//  ★【新增】换图转场（第 2 级）：栅格化淡出 → 全黑 → 栅格化淡入  【加分项②】
// -------------------------------------------------------------------------
//  数据流：vout_proc → [fade_ctrl] → vout_fade → [osd_adjust] → ...
//
//  ★ 为什么放在 OSD 之前？
//    这样字幕和调节界面不会被一起压黑。转场时画面在闪，字幕照常滚动，
//    观感更专业（评委看到的是"画面在换、字幕不断"）。
//
//  ★ load_busy 跨时钟域：
//    它来自 sd_card_bmp（sd_card_clk = 100MHz 域），
//    本模块在 video_clk = 25MHz 域，必须打两拍同步后再用。
// =========================================================================
reg load_busy_s1, load_busy_s2;

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        load_busy_s1 <= 1'b0;
        load_busy_s2 <= 1'b0;
    end else begin
        load_busy_s1 <= load_busy_sd;    // 100MHz 域
        load_busy_s2 <= load_busy_s1;    // 25MHz 域
    end
end

// ★ 这里不覆盖任何参数，全部用 fade_ctrl.v 里的默认值：
//     GRID_LOG2=5  G_MAX=33  STEP_LOG2=1  FADE_LOG2=5
//     PHASE_TICK=98  TICK_DIV=5102  WAIT_SEC=4
//   转场总时长 = 98 x 5102 x 2 / 25MHz ≈ 40ms（固定，与轮播周期无关）
//   想改快慢只改 fade_ctrl.v 里的 TICK_DIV 一个数即可。
//   （不在这里写参数表，就不会出现"参数改名了忘了同步"这类编译错误）
fade_ctrl u_fade_ctrl (
    .video_clk   (video_clk),
    .rst         (rst_all),
    .I_de        (de_proc),
    .I_hs        (hs_proc),
    .I_vs        (vs_proc),
    .I_rgb       (vout_proc),
    .O_de        (de_fade),
    .O_hs        (hs_fade),
    .O_vs        (vs_fade),
    .O_rgb       (vout_fade),
    // 转场常开。拨码开关 4 个已经全部占满，如果以后想给它一个开关，
    // 把这里改成对应的配置位即可（video 配置字 bit[0] 还是空的）。
    .I_en        (1'b1),
    .I_load_busy (load_busy_s2),
    .I_period_sec(cfg_period_sec_v),   // ★ 转场时长 = 轮播周期的 1/10
    .I_frame_new (1'b0),
    .O_gain      (fade_gain),
    .O_state     (fade_state)
);

wire [23:0] vout_osd;
wire        hs_osd, vs_osd, de_osd;

// 当前要显示的数值：按当前调节项从三个参数里选一个
wire [15:0] osd_value = (vcfg_adj_sel == 2'd0) ? {11'd0, vcfg_brightness} :  // 亮度
                        (vcfg_adj_sel == 2'd1) ? {11'd0, vcfg_contrast}   :  // 对比度
                                                 {8'd0,  cfg_period_sec_v};   // 周期

osd_adjust u_osd_adjust (
    .video_clk (video_clk),
    .rst       (rst_all),
    // ★ 注意：输入接的是 fade_ctrl 的输出，不是 image_processor 的输出
    .I_de      (de_fade),
    .I_hs      (hs_fade),
    .I_vs      (vs_fade),
    .I_rgb     (vout_fade),
    .O_de      (de_osd),
    .O_hs      (hs_osd),
    .O_vs      (vs_osd),
    .O_rgb     (vout_osd),
    .I_show    (vcfg_adj_mode),      // ★ 只有调节模式才显示
    .I_sel     (vcfg_adj_sel),
    .I_value   (osd_value)
);

// =========================================================================
//  第四级：底部传送带字幕（加分项①）
// -------------------------------------------------------------------------
//  数据流：vout_osd → [marquee_osd] → vout_data → AXIS → HDMI
//
//  显示效果：
//      屏幕底部有一条半透明深色底条（y=440~479），
//      白字从右往左滚动，速度 50 像素/秒，
//      滚完一轮停 2 秒，然后循环。
//
//  文字来源：TF 卡上的字幕文件（开头必须是 #ZIMU#），
//            由 txt_read 在开机时读进 BRAM，再跨时钟域送过来。
//
//  ★ 本模块内部把像素和 hs/vs/de 都延迟 4 拍，所以下游必须用它输出的
//    de_marq / vs_marq，不能再用 de_osd / vs_osd。
//  ★ 字幕开关直接用 SW4（vcfg_osd_en），和调节 OSD 共用一个开关。
// =========================================================================
wire [23:0] vout_marq;
wire        hs_marq, vs_marq, de_marq;
// （marq_text_len 已经在上面 seg_display 之前声明过了，这里不再重复声明）

marquee_osd #(
    .CLK_FREQ  (25_000_000),   // 视频时钟 25MHz
    .SPEED_PPS (50),           // ★ 滚动速度 50 像素/秒
    .PAUSE_MS  (2000)          // ★ 两轮之间停 2 秒
) u_marquee_osd (
    .video_clk (video_clk),
    .rst       (rst_all),
    .I_de      (de_osd),
    .I_hs      (hs_osd),
    .I_vs      (vs_osd),
    .I_rgb     (vout_osd),
    .O_de      (de_marq),
    .O_hs      (hs_marq),
    .O_vs      (vs_marq),
    .O_rgb     (vout_marq),
    .I_show    (vcfg_osd_en),     // SW4：字幕总开关
    .I_idx     (txt_idx),
    .I_req_tgl (txt_req_tgl),
    .O_ack_tgl (txt_ack_tgl),
    .O_text_len(marq_text_len)
);

assign vout_data = vout_marq;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频 ACR 参数计算 =====================
//  原例程在这里是"内部 I2S 测试音(hdmi_audio_tone_i2s_64fs) +
//  I2S 接收解串(I2S_receiver)"，现在音频数据来自 TF 卡（见上方音频子系统），
//  这两个模块已删除，I_audio_valid 直接接 audio_player 的输出。
//
//  ACR (Audio Clock Regeneration) 的作用：
//    HDMI 接收端没有独立的音频时钟线，靠发送端在音频数据包里携带
//    CTS/N 两个参数来恢复采样时钟。N=6144 是 48kHz 的标准值；
//    CTS 由本模块根据实际 valid 速率动态测量，可自动跟踪微小频差。
audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (aud_valid),          // ★ 改接音频播放器的 valid
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
// ★ 注意：I_vs / I_de 必须接图像处理流水线最后一级输出的 vs_osd / de_osd，
//    它们与 vout_data 严格同拍；若接前面几级的信号会导致画面偏移或撕裂。
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs_marq),      // ★ 必须用最后一级(传送带)输出的同步信号
    .I_de          (de_marq),      //   —— 它比 vs_osd/de_osd 又晚 4 拍
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 音乐开关（SW3）=====================
//  关掉时只把"音频数据"置 0（静音），但 aud_valid 必须保持 48kHz 规律不变！
//  原因：HDMI 接收端靠 ACR（音频时钟恢复）锁定采样率，如果 valid 也跟着断掉，
//        接收端会失锁 → 电视端出现爆音/断音。
//        这和 audio_player 里"underrun 时只把数据置 0"是同一个道理。
//
//  ★ 只静音、不停 SD 卡读取：这样拨回来是瞬间恢复，没有重新加载的延迟，
//    代价仅仅是 SD 总线那 7% 的带宽（对图片轮播毫无影响）。
wire [23:0] aud_left_out  = vcfg_music_en ? aud_left  : 24'd0;
wire [23:0] aud_right_out = vcfg_music_en ? aud_right : 24'd0;

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    // ★【改造】音频数据来自 TF 卡（audio_player），不再是内部测试音
    .I_audio_valid      (aud_valid),
    .I_audio_left_data  (aud_left_out),     // ★ 经过 SW3 音乐开关
    .I_audio_right_data (aud_right_out),    // ★ 经过 SW3 音乐开关
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
