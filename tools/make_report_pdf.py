# -*- coding: utf-8 -*-
"""
生成《智能数字广告牌系统》作品报告 PDF（按赛题模板结构）
流程：PIL 画系统框图/流程图 + 从演示视频截实物图 + HTML 排版 + Edge 无头打印 PDF
"""
import os
import sys
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

DESKTOP = Path(os.environ.get('USERPROFILE', str(Path.home()))) / 'Desktop'
OUT_PDF = DESKTOP / '智能数字广告牌系统_作品报告.pdf'
TMP = Path(tempfile.gettempdir()) / 'adboard_report'
TMP.mkdir(parents=True, exist_ok=True)

VIDEO = Path(r'C:\Users\wys\AppData\Roaming\CherryStudio\Data\Files\01a19ba9-9d5c-71d0-87d3-05db6ee711a5.mp4')
EDGE = Path(r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe')
FFMPEG = Path(sys.base_prefix) / 'lib' / 'site-packages' / 'imageio_ffmpeg' / 'binaries' / 'ffmpeg-win-x86_64-v9.0.2.exe'

FONT_HEI = r'C:\Windows\Fonts\simhei.ttf'

# ============================================================
# 1. 从演示视频截两张实物图
# ============================================================
shots = []
if VIDEO.exists() and FFMPEG.exists():
    for i, (ts, name) in enumerate([('15', 'shot1.jpg'), ('56', 'shot2.jpg')]):
        out = TMP / name
        subprocess.run([str(FFMPEG), '-y', '-loglevel', 'error', '-ss', ts,
                        '-i', str(VIDEO), '-frames:v', '1',
                        '-vf', 'scale=1280:-1', '-q:v', '3', str(out)],
                       check=False)
        if out.exists():
            shots.append(out)

# ============================================================
# 2. PIL 画系统框图（图1）和软件流程图（图2）
# ============================================================
def font(sz):
    return ImageFont.truetype(FONT_HEI, sz)


def box(d, x, y, w, h, text, fill='#eaf2ff', outline='#2f5597', fs=20):
    d.rounded_rectangle([x, y, x + w, y + h], radius=8, fill=fill, outline=outline, width=2)
    lines = text.split('\n')
    f = font(fs)
    total = sum(d.textbbox((0, 0), ln, font=f)[3] for ln in lines) + (len(lines) - 1) * 4
    cy = y + (h - total) / 2
    for ln in lines:
        tw = d.textbbox((0, 0), ln, font=f)[2]
        d.text((x + (w - tw) / 2, cy), ln, font=f, fill='#1a1a1a')
        cy += d.textbbox((0, 0), ln, font=f)[3] + 4


def arrow(d, x1, y1, x2, y2, color='#2f5597', width=2):
    d.line([x1, y1, x2, y2], fill=color, width=width)
    import math
    ang = math.atan2(y2 - y1, x2 - x1)
    L = 10
    for a in (ang + 2.7, ang - 2.7):
        d.line([x2, y2, x2 + L * math.cos(a), y2 + L * math.sin(a)], fill=color, width=width)


# ---- 图 1 系统总体框图 ----
def poly_arrow(d, pts, color='#2f5597', width=2):
    import math
    for i in range(len(pts) - 1):
        d.line([pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]],
               fill=color, width=width)
    x1, y1 = pts[-2]
    x2, y2 = pts[-1]
    ang = math.atan2(y2 - y1, x2 - x1)
    L = 10
    for a in (ang + 2.7, ang - 2.7):
        d.line([x2, y2, x2 + L * math.cos(a), y2 + L * math.sin(a)],
               fill=color, width=width)


W, H = 1240, 760
im1 = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(im1)

# 顶部：存储与仲裁
box(d, 60, 60, 170, 60, 'TF 卡\n(FAT32)', '#fff2e0', '#c55a11')
box(d, 300, 60, 180, 60, 'SD 卡控制器\nSPI 25MHz')
box(d, 540, 60, 180, 60, '扇区级仲裁\n音频告急优先', '#fbe5d6', '#c55a11')
arrow(d, 230, 90, 300, 90)
arrow(d, 480, 90, 540, 90)

# 三通道（自上而下）
box(d, 300, 210, 180, 60, '图片通道\nbmp_read')
box(d, 300, 340, 180, 60, '音乐通道\nwav_read + FIFO')
box(d, 300, 470, 180, 60, '字幕通道\ntxt_read')
poly_arrow(d, [(630, 120), (630, 150), (390, 150), (390, 210)])
poly_arrow(d, [(630, 150), (630, 315), (390, 315), (390, 340)])
poly_arrow(d, [(630, 150), (630, 445), (390, 445), (390, 470)])

# 图片链路
box(d, 540, 210, 180, 60, '自适应缩放\nimg_scaler', '#e2f0d9', '#548235')
box(d, 780, 210, 190, 60, 'SDRAM 双缓冲\nBUF0 / BUF1', '#e2f0d9', '#548235')
arrow(d, 480, 240, 540, 240)
arrow(d, 720, 240, 780, 240)

# 音频链路
box(d, 540, 340, 180, 60, 'audio_player\n48kHz', '#e2f0d9', '#548235')
box(d, 780, 340, 190, 60, 'audio_level\n音量包络', '#e2f0d9', '#548235')
arrow(d, 480, 370, 540, 370)
arrow(d, 720, 370, 780, 370)

# 字幕链路
box(d, 540, 470, 180, 60, '字幕缓存\ntxt_mem')
arrow(d, 480, 500, 540, 500)

# 视频流水线 + HDMI
box(d, 300, 590, 660, 70,
    '视频流水线（25MHz）：亮度/对比度 → 转场 → 参数 OSD → 滚动字幕 → 音频波形',
    '#deebf7', '#2f5597', fs=19)
box(d, 1010, 590, 180, 70, 'HDMI 1.4b\n视频 + 音频', '#d9e2f3', '#1f4e79')
arrow(d, 960, 625, 1010, 625)

# SDRAM / audio_level / 字幕缓存 → 视频流水线
poly_arrow(d, [(970, 240), (1080, 240), (1080, 560), (930, 560), (930, 590)])
poly_arrow(d, [(875, 400), (875, 590)])
poly_arrow(d, [(630, 530), (630, 590)])

# 控制链路
box(d, 60, 210, 170, 60, '按键 / 拨码\n(50MHz)', '#fff2cc', '#bf8f00')
box(d, 60, 340, 170, 60, 'key_ctrl_fsm', '#fff2cc', '#bf8f00')
box(d, 60, 470, 170, 60, 'cfg_cdc ×5\n翻转握手', '#fff2cc', '#bf8f00')
arrow(d, 145, 270, 145, 340)
arrow(d, 145, 400, 145, 470)
poly_arrow(d, [(230, 500), (265, 500), (265, 625), (300, 625)])

# ---- 图 2 软件流程图 ----
W2, H2 = 1120, 720
im2 = Image.new('RGB', (W2, H2), 'white')
d2 = ImageDraw.Draw(im2)

steps = [
    (60, 90, 260, 60, '上电 / 复位\nSD 初始化'),
    (380, 90, 300, 60, '扫描 TF 卡 BMP\n缓存前 8 张起始地址'),
    (740, 90, 280, 60, '首图装载\n写 BUF0 并显示'),
    (740, 230, 280, 60, '显示运行\n(轮播 / 手动切图)'),
    (60, 230, 300, 60, '按键 / 拨码\n参数经 cfg_cdc 跨域'),
    (60, 370, 300, 60, '缩放值变化\n置 zoom_pending'),
    (60, 510, 300, 60, '等待 300ms 静默\n或连按 400ms 兜底'),
    (380, 510, 320, 60, '节流 400ms 到期\n且总线空闲 → 发起重载'),
    (380, 370, 320, 60, '装载优先级\n首图 > 切图 > 缩放 > 轮播'),
    (380, 230, 320, 60, '读文件头 / 读像素\nimg_scaler 等比缩放'),
    (740, 370, 280, 60, '写非显示缓冲\n(BUF1 / BUF0)'),
    (740, 510, 280, 60, '整帧写完 → 单拍切换\n换图才触发转场'),
]
for x, y, w, h, t in steps:
    box(d2, x, y, w, h, t, fs=18)

arrow(d2, 320, 120, 380, 120)
arrow(d2, 680, 120, 740, 120)
arrow(d2, 880, 150, 880, 230)
arrow(d2, 740, 260, 360, 260)
arrow(d2, 210, 290, 210, 370)
arrow(d2, 210, 430, 210, 510)
arrow(d2, 360, 540, 380, 540)
arrow(d2, 540, 510, 540, 430)
arrow(d2, 540, 370, 540, 290)
arrow(d2, 680, 260, 740, 260)
arrow(d2, 880, 370, 880, 430)
arrow(d2, 880, 490, 880, 510)

fig1 = TMP / 'fig1_system.png'
fig2 = TMP / 'fig2_flow.png'
im1.save(fig1, quality=95)
im2.save(fig2, quality=95)

# ============================================================
# 3. 生成 HTML
# ============================================================
def img_tag(path, w='100%'):
    return '<img src="%s" style="width:%s"/>' % (Path(path).as_uri(), w)

shot_html = ''
for i, s in enumerate(shots[:1]):
    shot_html += ('<div class="fig"><img src="%s" style="width:88%%"/>'
                  '<div class="cap">图 3-1  系统实物与实时运行画面</div></div>' % Path(s).as_uri())
for i, s in enumerate(shots[1:2]):
    shot_html += ('<div class="fig"><img src="%s" style="width:88%%"/>'
                  '<div class="cap">图 3-2  广告图片、滚动字幕与音频波形叠加显示</div></div>' % Path(s).as_uri())

html = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<style>
@page { size: A4; margin: 18mm 16mm; }
body { font-family: "Microsoft YaHei", "SimSun", sans-serif; font-size: 10.5pt;
       line-height: 1.75; color: #1a1a1a; }
h1 { font-size: 19pt; text-align: center; margin: 4mm 0 2mm; letter-spacing: 1px; }
.sub { text-align: center; color: #555; font-size: 10pt; margin-bottom: 6mm; }
h2 { font-size: 14pt; margin: 7mm 0 3mm; padding-bottom: 1.5mm;
     border-bottom: 1.2pt solid #2f5597; color: #1f3864; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 4.5mm 0 2mm; color: #2f5597; page-break-after: avoid; }
p { margin: 1.4mm 0; text-align: justify; }
.ind { text-indent: 2em; }
table { width: 100%; border-collapse: collapse; margin: 2.5mm 0; font-size: 9.8pt; }
th, td { border: 0.6pt solid #8ea9db; padding: 1.6mm 2mm; text-align: center; }
th { background: #deeaf6; font-weight: bold; }
.fig { text-align: center; margin: 3mm 0; }
.fig img { max-width: 100%; }
.cap { font-size: 9pt; color: #444; margin-top: 1mm; }
ul, ol { margin: 1.5mm 0 1.5mm 5mm; padding: 0; }
li { margin: 1mm 0; }
.abs { background: #f5f8fc; border: 0.6pt solid #c9d7ea; padding: 3mm 4mm; margin: 3mm 0; }
.ref { font-size: 9.8pt; }
.pb { page-break-before: always; }
.note { color: #666; font-size: 9.5pt; }
</style></head><body>

<h1>基于安路 EG4S20 的智能数字广告牌系统</h1>
<div class="sub">2026 年全国大学生嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路科技 · 赛题一）</div>

<h2>摘要</h2>
<div class="abs">
<p>本作品面向智能数字广告牌应用，在安路 EG4S20 FPGA 上实现了一套完整的 HDMI 多媒体播放系统。系统从 TF 卡自动扫描 BMP 广告图片与 WAV 背景音乐，经 HDMI 接口以 640×480@60Hz 输出，支持 8 槽位自动/手动轮播、底部滚动字幕、换图栅格转场、亮度/对比度实时调节、画面缩放 50%~200%、音频波形可视化以及 6 位数码管状态显示。</p>
<p>针对单条 SD 卡 SPI 总线需同时服务图片、音乐、字幕的冲突，设计扇区级三级仲裁（音频 FIFO 告急 &gt; 字幕 &gt; 图片 &gt; 音频补货），在图片连续装载期间保证音乐不中断；显示端采用 SDRAM 双缓冲，整帧写满后单拍切换，无撕裂无闪烁；图像缩放采用比较式 DDA 算法在装载链路实现，全程仅加减与比较、无乘除法，在块 RAM 余量仅 8 块的条件下完成；音频可视化采用幅度包络检测驱动绿色波形显示，不占用块 RAM。系统同时设计了缩放重载的三级调度（300ms 静默 + 400ms 强制兜底 + 400ms 节流）与 SD 通信故障自恢复机制，保证长期运行的稳定性。</p>
<p>实测图片装载约 350ms/张，音频占用总线带宽约 6.9%，轮播、音乐、字幕、转场、缩放与波形显示功能运行稳定。项目以 Python 逐拍仿真驱动开发，关键模块均在上板前完成像素级验证。</p>
</div>

<h2>第一部分  作品概述</h2>

<h3>1.1 功能与特性</h3>
<p class="ind">作品以“图片轮播 + 音频流”的形式实现数字广告牌的核心功能：上电后自动扫描 TF 卡中的 BMP 资源，按 5~30 秒可调周期自动轮播，也支持按键手动切图；屏幕底部叠加从右向左滚动的中文字幕（745 汉字库，UTF-8 解码），左上角实时显示亮度、对比度、轮播周期与缩放参数；换图时播放栅格化转场特效，旧图逐格淡出、新图逐格浮现。</p>
<p class="ind">音频方面，系统从 TF 卡流式播放 48kHz/16bit/立体声 WAV 音乐，支持无缝循环，并在图片装载期间保持不断音。画面调节提供亮度、对比度（0~31）与 50%~200% 中心等比缩放（缩小时补黑边、放大时居中裁切）。在字幕上方新增绿色音频波形显示，随音乐节奏跳动，音乐关闭时自动变为一条直线。6 位数码管实时显示运行状态与调节参数，便于演示与排障。</p>

<h3>1.2 应用领域</h3>
<p class="ind">本作品可直接应用于商场、校园、车站等场所的数字广告牌与信息发布终端：低成本 FPGA 方案相比 ARM + 安卓主板具有启动快、时序确定、接口可扩展的优势，适合长时间无人值守运行。系统的图片轮播、滚动字幕、音频播放与转场特效组合，也可用于展厅多媒体展示、活动现场信息屏、教学实验平台等场景。</p>
<p class="ind">在技术层面，本作品涉及的 SD 卡总线仲裁、SDRAM 双缓冲显示、跨时钟域参数传输、图像缩放流水线等模块，可作为 FPGA 多媒体处理方向的教学参考设计，展示从外设驱动、数据调度到显示输出的完整工程链路。</p>

<h3>1.3 主要技术特点</h3>
<p class="ind">（1）单总线多媒体调度：图片、音乐、字幕共用一条 SPI 总线，以扇区为原子单位进行仲裁，音频 FIFO 水位低时绝对抢占，保证音画并行。（2）无撕裂显示：SDRAM 划分为两块帧缓存，装载写入非显示缓冲，整帧写完才切换指针。（3）零乘除法缩放：采用比较式 DDA 实现 50%~200% 等比缩放，仅消耗一块行缓存。（4）语义化转场触发：仅“换图”触发栅格转场，缩放重载直接切换画面，避免连续重载时转场雪崩。（5）完整跨时钟域设计：多比特参数经 1 位翻转握手传输，单比特事件打两拍同步，视频流水线每级补齐同步延迟。</p>

<h3>1.4 主要性能指标</h3>
<table>
<tr><th>指标</th><th>数值</th><th>指标</th><th>数值</th></tr>
<tr><td>视频输出</td><td>640×480@60Hz HDMI 1.4b</td><td>图片装载</td><td>约 350ms/张</td></tr>
<tr><td>音频格式</td><td>48kHz / 16bit / 立体声</td><td>音频带宽占用</td><td>约 6.9%</td></tr>
<tr><td>轮播周期</td><td>5~30 秒可调</td><td>缩放范围</td><td>50%~200%，步进 5%</td></tr>
<tr><td>缩放响应</td><td>连按约 450ms/档</td><td>块 RAM 占用</td><td>56/64 块</td></tr>
</table>

<h3>1.5 主要创新点</h3>
<ol>
<li><b>扇区级三级仲裁</b>：音频告急优先、图片次之、字幕插空、空闲补音频，用硬件保证多媒体场景下不断音。</li>
<li><b>比较式 DDA 缩放</b>：以累加器比较替代除法器，在无 DSP、块 RAM 紧张的器件上实现实时缩放。</li>
<li><b>语义信号分离转场触发</b>：新增 img_switch 信号区分“换图”与“同图重载”，根治转场误触发导致的连环黑屏。</li>
<li><b>缩放重载三级调度</b>：静默期 + 强制刷新兜底 + 节流门闩，兼顾跟手体验与总线负载。</li>
<li><b>SD 通信故障自恢复</b>：状态停留超时后自动重新初始化，运行中卡故障可自愈，无需断电重启。</li>
</ol>

<h3>1.6 设计流程</h3>
<p class="ind">设计按“需求分析 → 架构划分 → 模块实现 → 逐拍仿真 → 综合布局 → 上板验证”推进：先完成 HDMI 显示与 SD 卡读取基础链路，再逐个加入轮播、音频、字幕、转场、缩放与波形功能；每个关键模块编写 Python 逐拍仿真模型，与 RTL 语义一致，修复问题后保留“复现旧 bug”的回归用例；最后通过 TD 综合布局生成比特流，在开发板上完成整机联调。</p>

<h2>第二部分  系统组成及功能说明</h2>

<h3>2.1 整体介绍</h3>
<p class="ind">系统由存储子系统、视频流水线、音频通路与人机交互四部分组成，整体框图如图 1 所示。TF 卡中的图片、音乐、字幕三路数据经扇区级仲裁共享一条 SPI 总线：图片通道由 bmp_read 解析 BMP、img_scaler 完成等比缩放后写入 SDRAM 双缓冲；音乐通道经异步 FIFO 送入 audio_player 产生 48kHz 音频；字幕通道解码 UTF-8 文本并缓存字符索引。显示端从 SDRAM 按 640×480@60Hz 读出，依次经过亮度/对比度、转场、参数 OSD、滚动字幕与音频波形五级处理，最后经 HDMI 发射核输出。按键与拨码产生的参数经翻转握手跨时钟域送至各模块。</p>
<div class="fig">%FIG1%<div class="cap">图 1  系统总体框图</div></div>

<h3>2.2 硬件系统介绍</h3>
<p class="ind"><b>2.2.1 硬件整体介绍：</b>系统采用安路 HX4S20C 开发板（EG4S20BG256，约 2 万 LUT、64 块 9Kb 块 RAM、片内 8MB SDRAM），外接 HDMI 显示器与 TF 卡。板载 50MHz 晶振经三组 PLL 产生 100MHz（SD 与装载）、125MHz（SDRAM 与 TMDS）、25MHz（视频流水线）与 12.288MHz（HDMI 音频）时钟。</p>
<p class="ind"><b>2.2.2 机械设计介绍：</b>本作品基于现成开发板与标准显示器搭建，无自定义机械结构；演示时将开发板通过 HDMI_B 接口连接显示器、插入 TF 卡即可运行。</p>
<p class="ind"><b>2.2.3 电路各模块介绍：</b>主要外部接口如表所示。视频与音频统一从 HDMI_B 口输出；按键 KEY_1~KEY_4 分别对应复位、参数减、切图/切换调节项、参数加；拨码 SW1~SW4 分别控制调节模式、自动轮播、音乐开关、字幕/OSD 开关；TF 卡以 SPI 模式（25MHz）读写，要求 FAT32 格式。</p>
<table>
<tr><th>接口</th><th>引脚/资源</th><th>说明</th></tr>
<tr><td>HDMI_B</td><td>HDMI 接口</td><td>视频 + 音频输出</td></tr>
<tr><td>KEY_1~4</td><td>A2 / B2 / B1 / C1</td><td>复位 / 减 / 切图或切项 / 加</td></tr>
<tr><td>SW1~4</td><td>C8 / C7 / C6 / C5</td><td>调节模式 / 轮播 / 音乐 / 字幕</td></tr>
<tr><td>TF 卡</td><td>SPI</td><td>FAT32，存 BMP/WAV/TXT</td></tr>
<tr><td>数码管</td><td>6 位共阳</td><td>状态码与参数显示</td></tr>
</table>

<h3>2.3 软件系统介绍</h3>
<p class="ind"><b>2.3.1 软件整体介绍：</b>软件按“按模块划分、按功能分层”设计：50MHz 域负责按键与拨码采集；100MHz 域负责 SD 卡驱动、图片扫描/装载/缩放、WAV 流式读取与字幕解码；125MHz 域负责 SDRAM 双缓冲读写；25MHz 域负责视频流水线与音频播放。各时钟域之间只通过同步器或 1 位翻转握手传递信号，避免多比特亚稳态。</p>
<p class="ind"><b>2.3.2 软件各模块介绍：</b>图片装载与缩放重载流程如图 2 所示。sd_card_bmp 状态机按优先级调度装载：首图 &gt; 手动切图 &gt; 缩放重载 &gt; 自动轮播；“缩放重载”采用 300ms 静默、400ms 强制刷新兜底与 400ms 节流三级策略，既保证单按快速响应，又避免长按连发时疯狂装载。img_scaler 内部为 8 状态机，依次完成目标尺寸计算、裁切起点计算、行缓存等待与 DDA 取样输出，输出 4 分频写入 FIFO。</p>
<div class="fig">%FIG2%<div class="cap">图 2  图片装载与缩放重载流程</div></div>
<table>
<tr><th>模块</th><th>功能</th><th>时钟域</th></tr>
<tr><td>key_ctrl_fsm / cfg_cdc</td><td>按键拨码 → 参数；翻转握手跨域</td><td>50MHz / 跨域</td></tr>
<tr><td>sd_bus_arbiter</td><td>图片/音乐/字幕扇区级仲裁</td><td>100MHz</td></tr>
<tr><td>sd_card_bmp / bmp_read</td><td>扫描、装载、双缓冲轮播调度、BMP 解析</td><td>100MHz</td></tr>
<tr><td>img_scaler</td><td>等比缩放 50%~200%（比较式 DDA）</td><td>100MHz</td></tr>
<tr><td>wav_read / txt_read</td><td>WAV 流式读取 / UTF-8 字幕解码</td><td>100MHz</td></tr>
<tr><td>frame_read_write / sdram</td><td>SDRAM 双缓冲</td><td>125MHz</td></tr>
<tr><td>image_processor / fade_ctrl / osd_adjust</td><td>亮度对比度 / 栅格转场 / 参数 OSD</td><td>25MHz</td></tr>
<tr><td>marquee_osd / audio_wave_osd</td><td>滚动字幕 / 音频波形显示</td><td>25MHz</td></tr>
<tr><td>audio_player / audio_level</td><td>48kHz 音频节拍 / 音量包络</td><td>25MHz</td></tr>
</table>

<h2>第三部分  完成情况及性能参数</h2>

<h3>3.1 整体介绍</h3>
<p class="ind">系统实物由 HX4S20C 开发板、HDMI 显示器与 TF 卡组成。上电后约数秒内完成 SD 卡初始化与图片扫描，屏幕显示首张广告图，底部字幕开始滚动，音频波形随音乐跳动；板载按键与拨码可实时切换图片、调节参数。实物运行画面见图 3-1、图 3-2。</p>
%SHOTS%

<h3>3.2 工程成果</h3>
<p class="ind"><b>3.2.1 机械成果：</b>无自定义机械结构，采用开发板与显示器的标准连接方式。</p>
<p class="ind"><b>3.2.2 电路成果：</b>完成开发板 HDMI、TF 卡、按键、拨码与数码管接口的完整使用与引脚约束（pin.adc），并验证了 HDMI_B 口音视频同时输出的稳定性。</p>
<p class="ind"><b>3.2.3 软件成果：</b>完成 20 余个 RTL 模块的设计与集成，形成“SD 卡多媒体调度 + SDRAM 双缓冲显示 + 视频流水线”的完整软件架构；配套 Python 逐拍仿真脚本 6 套，覆盖图像缩放、缩放重载决策、转场触发、音频波形、BMP 解析与端到端链路。</p>

<h3>3.3 特性成果</h3>
<table>
<tr><th>测试项</th><th>设计指标</th><th>实测结果</th></tr>
<tr><td>HDMI 输出</td><td>640×480@60Hz</td><td>稳定显示，无闪屏</td></tr>
<tr><td>图片轮播</td><td>5~30 秒可调</td><td>周期误差 &lt; 0.1s</td></tr>
<tr><td>音乐播放</td><td>48kHz/16bit/立体声</td><td>连续播放，装载期间不断音</td></tr>
<tr><td>字幕滚动</td><td>50 像素/秒</td><td>平滑滚动，循环显示</td></tr>
<tr><td>换图转场</td><td>栅格淡出/淡入</td><td>正常；缩放重载不触发转场</td></tr>
<tr><td>亮度/对比度</td><td>0~31</td><td>OSD 数值同步，画面变化明显</td></tr>
<tr><td>画面缩放</td><td>50%~200%</td><td>比例正确，补黑边/裁切正常</td></tr>
<tr><td>音频波形</td><td>随音量跳动</td><td>静音一条直线，播放时随节奏抖动</td></tr>
<tr><td>长时间运行</td><td>—</td><td>SD 通信故障可自动恢复</td></tr>
</table>

<h2>第四部分  总结</h2>

<h3>4.1 可扩展之处</h3>
<p class="ind">受 SD 卡 SPI 模式带宽限制（上限约 3MB/s），当前以约 3 帧/秒的图片轮播实现“伪视频”，后续可改用 SD 卡 4bit 模式（带宽提升约 4 倍）或上电预载 SDRAM 提升帧率；音频可视化目前为幅度包络波形，可进一步扩展为频率轴可视化（需权衡乘法器与块 RAM 资源）；转场音量联动接口（fade_ctrl.O_gain）已预留，接入音频通路即可实现音视频联动加分项；此外可将 PC 端 AI 生成的广告素材与本系统结合，形成“AI 素材生成 + FPGA 播放”的完整方案。</p>

<h3>4.2 心得体会</h3>
<p class="ind">这个项目从零开始，我们三人组之前都没有接触过 FPGA。最初面对赛题例程时，几乎所有模块都看不懂；我们从点亮 HDMI、读一张图片开始，一点点把整个系统拆开又拼起来。</p>
<p class="ind">过程中最大的收获是学会了“用仿真代替反复上板”。板上调试一次要编译十几分钟、下载、观察，出了问题只能靠猜；而用 Python 按 RTL 逐拍建模后，很多问题在电脑上就能复现——比如缩放器丢像素、行缓存错位、缩放重载的静默期把更新全挡死、转场特效被缩放重载连环触发导致黑屏。我们把每个 bug 都做成可复现的仿真用例，修复后保留“旧版对照”，这比单纯改代码有价值得多。</p>
<p class="ind">第二个收获是对“资源”的敬畏。EG4S20 的块 RAM 只有 64 块，用到 56 块后几乎寸步难行：加一行缓存、放一个波形数组，都要先算清楚会不会占用块 RAM。也正因为资源紧张，我们才想出了比较式 DDA、纯逻辑波形、分布式 RAM 这些在资源上“抠”出来的方案，反而成了作品的特色。</p>
<p class="ind">第三个收获是理解了“时序”和“现象”的关系。上板后遇到的黑屏、卡死、数码管状态异常，最后大多能追到具体的信号：数码管位5=0 说明 SD 初始化掉了，位5=1 但没图说明扫描没找到文件，缩放卡死有时是调度逻辑、有时是 SD 通信故障。学会先看可观测信号、再做假设验证，比盲目改代码效率高太多。</p>
<p class="ind">最后要感谢 AI 工具的帮助。我们把它当成“随时在线的搭档”：帮我们读例程、推时序、写仿真脚本、分析上板现象；但最终拍板的还是我们自己——哪些建议能采信、参数该取多少、硬件现象是否可信，都要靠对代码和现象的理解来判断。这个项目让我们真正体会到，工具可以放大能力，但基础和理解才是根本。</p>

<h2>第五部分  参考文献</h2>
<div class="ref">
<p>[1] 安路科技. Eagle 系列 FPGA 用户手册与 TD 软件开发指南.</p>
<p>[2] 康华光. 电子技术基础（数字部分）（第六版）. 北京：高等教育出版社, 2013.</p>
<p>[3] 全国大学生嵌入式芯片与系统设计竞赛组委会. 2026 年竞赛指南（FPGA 赛道）.</p>
<p>[4] HDMI Licensing. HDMI Specification 1.4b.</p>
<p>[5] SD Association. SD Specifications Part 1: Physical Layer Simplified Specification.</p>
<p>[6] 王诚. Verilog HDL 数字系统设计（第二版）. 北京：人民邮电出版社, 2012.</p>
<p>[7] 罗杰, 谢自美. 电子线路——设计·实验·测试（第五版）. 北京：电子工业出版社, 2015.</p>
<p>[8] 安路科技. EG4 系列 FPGA 器件数据手册.</p>
</div>

</body></html>"""

html = html.replace('%FIG1%', img_tag(fig1)).replace('%FIG2%', img_tag(fig2)).replace('%SHOTS%', shot_html)

html_path = TMP / 'report.html'
html_path.write_text(html, encoding='utf-8')

# ============================================================
# 4. Edge 无头打印 PDF
# ============================================================
subprocess.run([
    str(EDGE), '--headless', '--disable-gpu', '--no-pdf-header-footer',
    '--virtual-time-budget=15000',
    '--print-to-pdf=' + str(OUT_PDF),
    html_path.as_uri()
], check=False)

if OUT_PDF.exists():
    print('PDF 已生成: %s' % OUT_PDF)
    print('大小: %.1f KB' % (OUT_PDF.stat().st_size / 1024))
else:
    print('PDF 生成失败')
    sys.exit(1)
