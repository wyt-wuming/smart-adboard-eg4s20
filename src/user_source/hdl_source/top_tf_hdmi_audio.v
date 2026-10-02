
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 按键 KEY_3（引脚 B1）★ 相对例程已改引脚
    input                       key2,           // 按键 KEY_4（引脚 C1）

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
wire       cfg_fade_en;         // 转场使能        → 送 video_clk 域
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
    .sw_mode          (sw1_sync1),
    .sw_auto          (sw2_sync1),
    .sw_trans         (sw3_sync1),
    .sw_osd           (sw4_sync1),
    .O_period_sec     (cfg_period_sec),
    .O_brightness     (cfg_brightness),
    .O_contrast       (cfg_contrast),
    .O_adj_sel        (cfg_adj_sel),
    .O_key_next_pulse (key_next_pulse),
    .O_adj_mode       (cfg_adj_mode),
    .O_auto_play      (cfg_auto_play),
    .O_fade_en        (cfg_fade_en),
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
//   [4:3]   调节项 [2]    转场开关 [1] OSD 开关   [0] 预留
wire [15:0] cfg_video_src = {
    cfg_brightness,      // [15:11]
    cfg_contrast,        // [10:6]
    cfg_adj_mode,        // [5]
    cfg_adj_sel,         // [4:3]
    cfg_fade_en,         // [2]   转场开关（SW3）
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
wire       vcfg_fade_en    = cfg_video[2];   // 转场开关（阶段 3 使用）
wire       vcfg_osd_en     = cfg_video[1];   // OSD 开关（阶段 1e 使用）

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
wire [1:0]  img_idx_sd;           // 当前第几张
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

// ---- WAV 扫描启动脉冲（等 SD 卡初始化完成后延迟一小段再扫描）----
reg  [21:0] wav_scan_dly;
reg         wav_scan_start;

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        wav_scan_dly   <= 22'd0;
        wav_scan_start <= 1'b0;
    end else begin
        wav_scan_start <= 1'b0;
        if (sd_init_done_bus) begin
            if (wav_scan_dly < 22'h3F_FFFF)
                wav_scan_dly <= wav_scan_dly + 22'd1;
            else if (wav_scan_dly == 22'h3F_FFFF) begin
                wav_scan_start <= 1'b1;         // 单拍脉冲，启动 WAV 扫描
                wav_scan_dly   <= 22'h3F_FFFF + 22'd1;
            end
        end
    end
end

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
    .wav_fifo_wrusedw        (audio_fifo_wrusedw),
    .O_grant_bmp             (),
    .O_grant_wav             ()
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
    .I_gain             (8'd255),           // 原音量（阶段3 接入淡入淡出联动）
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

seg_display u_seg_display (
    .I_state_code (state_code),
    .I_adj_mode   (cfg_adj_mode),
    .I_adj_sel    (cfg_adj_sel),
    .I_auto_play  (auto_play_sync1),
    .I_value      (seg_value),
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

assign vout_data = vout_proc;

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
// ★ 注意：I_vs / I_de 必须接图像处理流水线输出后的 vs_proc / de_proc，
//    它们与 vout_data 严格同拍；若接原始的 vs / de 会导致画面偏移或撕裂。
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs_proc),
    .I_de          (de_proc),
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
    .I_audio_left_data  (aud_left),
    .I_audio_right_data (aud_right),
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
