# 基于安路 EG4S20 的智能数字广告牌系统

2026 年全国大学生嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路科技 · 赛题一）

本仓库是赛题一"基于安路 EG4S20 的 HDMI 多媒体播放系统"的参赛工程，在原厂例程基础上完成了显示、存储、音频、字幕、转场、缩放与音频可视化等功能的自主设计与改造。

## 功能特性

- HDMI 视频输出：640×480@60Hz，SDRAM 双缓冲，无撕裂切换
- 图片播放：TF 卡自动扫描 BMP（缓存前 8 张），自动轮播（5~30 秒可调）与手动切图
- 音频播放：WAV（48kHz / 16bit / 立体声）无缝循环，图片装载期间不断音
- 滚动字幕：745 汉字库，UTF-8 解码，底部传送带式滚动
- 栅格转场：换图时旧图淡出、新图淡入；缩放重载不触发转场
- 亮度 / 对比度：0~31 实时调节，参数 OSD 显示
- 画面缩放：50%~200%（中心基准、等比、缩小时补黑边、放大时居中裁切）
- 音频可视化：字幕上方绿色波形，随音乐跳动；静音时显示为一条直线；调节模式下自动隐藏
- 状态显示：6 位数码管显示装载状态、模式、参数

## 系统架构

```
TF 卡 --SPI--> SD 卡控制器 --> 扇区级仲裁（音频告急 > 字幕 > 图片 > 音频补货）
                                  |
              +-------------------+-------------------+
              |                   |                   |
         图片通道 bmp_read    音乐通道 wav_read   字幕通道 txt_read
              |                   |                   |
        img_scaler 缩放      异步 FIFO          字幕缓存
              |                   |                   |
       SDRAM 双缓冲         audio_player        marquee_osd
       (BUF0/BUF1)              |                   |
              |             HDMI 音频               |
              +-------------------+-------------------+
                                  |
          视频流水线（25MHz）：
          image_processor -> fade_ctrl -> osd_adjust
          -> marquee_osd -> audio_wave_osd
                                  |
                          HDMI 1.4b 发射核 -> 显示器
```

时钟域划分：

| 时钟 | 频率 | 主要模块 |
|---|---|---|
| clk | 50MHz | 按键 / 拨码 |
| sd_card_clk | 100MHz | SD 卡、图片装载、缩放、音频 / 字幕读取 |
| ext_mem_clk | 125MHz | SDRAM 双缓冲 |
| video_clk | 25MHz | 视频流水线、音频播放 |
| hdmi_5x_clk | 125MHz | TMDS 串行化 |

## 硬件平台

| 项目 | 说明 |
|---|---|
| 开发板 | HX4S20C（EG4S20BG256） |
| 显示接口 | HDMI_B 口（视频与音频均从此口输出） |
| 存储 | TF 卡，FAT32 格式 |
| 晶振 | 50MHz（R7） |
| 按键 | KEY_1(A2) 复位 / KEY_2(B2) 参数减 / KEY_3(B1) 切图或切换调节项 / KEY_4(C1) 参数加 |
| 拨码 | SW1(C8) 调节模式 / SW2(C7) 自动轮播 / SW3(C6) 音乐 / SW4(C5) 字幕与 OSD |

## 软件结构

| 模块 | 功能 | 时钟域 |
|---|---|---|
| key_ctrl_fsm / cfg_cdc | 按键拨码采集；参数翻转握手跨域 | 50MHz |
| sd_card_top / sd_bus_arbiter | SPI 物理层；图片 / 音乐 / 字幕扇区级仲裁 | 100MHz |
| sd_card_bmp / bmp_read | 扫描、装载、双缓冲轮播调度；BMP 解析 | 100MHz |
| img_scaler | 比较式 DDA 等比缩放 50%~200% | 100MHz |
| wav_read / txt_read | WAV 流式读取；UTF-8 字幕解码 | 100MHz |
| frame_read_write / sdram | SDRAM 双缓冲读写 | 125MHz |
| image_processor / fade_ctrl / osd_adjust | 亮度对比度；栅格转场；参数 OSD | 25MHz |
| marquee_osd / audio_wave_osd | 滚动字幕；音频波形显示 | 25MHz |
| audio_player / audio_level | 48kHz 音频节拍；音量包络检测 | 25MHz |
| seg_display / seg_scan | 数码管内容合成与动态扫描 | 50MHz |

## 快速开始

1. 准备 TF 卡：格式化为 FAT32，根目录放 BMP 图片（24bit 未压缩）、WAV 音乐（48000Hz / 16bit / 立体声）、字幕文件（UTF-8，开头 `#ZIMU#`）。
2. 打开 TD 工程：`src/td_project/HDMI1.4b_Transmitter_v1.0.al`。
3. 依次执行 Run Synthesis、Run Physical Design，等待生成比特流。
4. 使用 Tools -> BitWriter 选择生成的文件下载：
   `src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0.bit`
5. 将显示器接 HDMI_B 口，插入 TF 卡，上电即可运行。

## 操作说明

调节模式（SW1 拨到 ON）下，用 KEY_3 循环切换调节项：

| 调节项 | 范围 | 说明 |
|---|---|---|
| 亮度 | 0~31 | 16 为中性 |
| 对比度 | 0~31 | 16 为中性 |
| 轮播周期 | 5~30 秒 | 仅自动轮播开启时生效 |
| 缩放 | 50%~200% | 步进 5%，中心等比缩放 |

数码管（从左到右）：

- 位 5：装载状态码（1 空闲 / 2 扫描 / 3 等待 / 4 装载）
- 位 4：1 运行模式 / 2 调节模式
- 位 3：A 自动轮播中 / 横杠 已关闭；调节模式下为 1~4 表示当前调节项
- 位 2、1：当前参数数值（缩放为百分比除以 10）
- 位 0：分隔符

## 仿真验证

`tools/` 目录下保留了一套 Python 逐拍仿真，用于上板前验证关键逻辑：

| 脚本 | 内容 | 结果 |
|---|---|---|
| 仿真_缩放.py | img_scaler 像素级验证 | 10/10 |
| 仿真_缩放跳跃.py | 缩放重载决策（静默 / 兜底 / 节流） | 5/5 |
| 仿真_转场触发.py | 转场只对换图触发 | 4/4 |
| 仿真_音频波形.py | 波形分段与绘制逻辑 | 10/10 |
| 仿真_bmp读取.py | BMP 解析与行填充 | 通过 |
| 仿真_端到端.py | bmp_read 到 img_scaler 连续多帧 | 通过 |

## 目录结构

```
lab_ex5_i2s/
├── src/
│   ├── user_source/
│   │   ├── hdl_source/            RTL 源码
│   │   │   ├── top_tf_hdmi_audio.v
│   │   │   ├── common/            按键与 CDC
│   │   │   ├── SD/                SD 卡、图片、音频、字幕、数码管
│   │   │   ├── video/             视频流水线、音频播放、波形
│   │   │   ├── include/           SDRAM 控制器等
│   │   │   └── hdmi1.4b_transmitter_core/  HDMI 发射核（厂商标密）
│   │   └── constraints_source/    引脚与时序约束
│   └── td_project/                TD 工程
├── tools/                         Python 仿真与生成工具
├── doc/                           交接文档、代码结构说明、图片转换工具
├── 1_保存当前进度.bat             本地存档
├── 2_还原到可用版.bat             回退到可用版本
├── 3_查看历史版本.bat             查看提交历史
├── 4_打包给队友.bat               生成源码同步包
└── 5_同步到GitHub.bat             一键提交并推送
```

## 注意事项

- **块 RAM 余量很小**（56/64 块），新增功能不要占用块 RAM，优先使用分布式 RAM 或纯逻辑。
- **新增 `.v` 文件必须加入 TD 工程**（Project -> Add Files），否则综合报 HDL-8007 / HDL-7144（black box / unknown module）。
- **更换 TF 卡图片不要手动删除**：系统按物理扇区扫描 `BM` 头，删除文件只删目录记录，数据仍在扇区中，会被继续扫描到。请使用 `doc/convert/sync_to_sd.py` 流程（先破坏旧图文件头）或完全格式化 TF 卡。
- 缩放重载节奏：静默 300ms + 强制兜底 400ms + 节流 400ms + 装载约 350ms；连按约 450ms 跟一档，松手约 750ms 到位。
- 本次综合存在时序违例（WNS 约 -29ns，布局利用率约 96%），最差路径为缩放器横向 DDA 组合逻辑；常温实际运行正常，若出现缩放偶发错位，优先怀疑该路径。
- 本仓库包含安路及开发板厂商提供的加密 IP 与例程文件，仅用于本比赛学习与评审，请勿公开传播。

## 参考资料

- 安路科技 Eagle 系列 FPGA 用户手册、TD 软件使用指南
- HDMI 1.4b 规范
- SD 卡物理层简化规范
