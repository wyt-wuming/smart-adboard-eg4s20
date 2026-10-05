# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 检查TF卡.py
 功能   : 检查 TF 卡上的素材文件是否满足播放要求（双击运行即可）
------------------------------------------------------------------------------
 用法：
   1) 把 TF 卡插到电脑上，看清楚它的盘符（比如 F: 或 G:）
   2) 双击本文件，或者命令行运行：  python 检查TF卡.py F
      （F 换成你实际的盘符，不带冒号）
==============================================================================
"""
import os
import sys
import struct

# ---- 1. 确定盘符（不给参数就自动找）----
if len(sys.argv) >= 2:
    drive = sys.argv[1].rstrip(':').rstrip('\\/') + ':'
else:
    drive = None
    found = []
    for c in 'DEFGHIJKLMNOPQRSTUVWXYZ':
        r = c + ':/'
        if not os.path.exists(r):
            continue
        try:
            names = [n.upper() for n in os.listdir(r) if os.path.isfile(os.path.join(r, n))]
        except Exception:
            continue
        # 像 TF 卡的特征：有 bmp 或 wav 或 txt
        if any(n.endswith(('.BMP', '.WAV', '.TXT')) for n in names):
            found.append(c + ':')
    if len(found) == 1:
        drive = found[0]
        print('自动找到 TF 卡： %s' % drive)
    elif len(found) > 1:
        print('找到多个可能的盘： %s' % ', '.join(found))
        drive = found[0]
        print('先用 %s 检查；如果不对，运行  python 检查TF卡.py G  （G 换成正确盘符）' % drive)
    else:
        drive = 'F:'

root = drive + '/'
print('=' * 62)
print('检查 TF 卡： %s' % root)
print('=' * 62)

if not os.path.exists(root):
    print()
    print('!! 找不到 %s' % root)
    print('   请确认卡插好了，并把盘符作为参数传进来，例如：')
    print('       python 检查TF卡.py G')
    sys.exit(1)

# ---- 2. 列出所有文件 ----
print()
print('【第 1 步】卡上的文件')
print('-' * 62)
files = []
try:
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            sz = os.path.getsize(p)
            files.append((name, sz))
            print('  %-32s %10d 字节  (%6.2f MB)' % (name, sz, sz / 1048576.0))
except Exception as e:
    print('  读目录失败：', e)

if not files:
    print('  (空)')

# ---- 3. 检查字幕文件 ----
print()
print('【第 2 步】字幕文件检查  ★ 最关键')
print('-' * 62)

MARK = b'#ZIMU#'
cands = [n for n, _ in files if n.upper().endswith('.TXT')]
if not cands:
    print('  !! 卡上没有任何 .TXT 文件 —— 这就是没有字幕的原因')
    print('     解决：把 E:\\project qianrushi\\anlu\\ZIMU.TXT 拷到卡根目录')
else:
    for name in cands:
        p = os.path.join(root, name)
        data = open(p, 'rb').read()
        head = data[:16]
        print('  文件：%s  (%d 字节)' % (name, len(data)))
        print('    原始前 16 字节 :', ' '.join('%02X' % b for b in head))
        ok = data[:6] == MARK
        print('    开头是 #ZIMU# ? :', '是 ✅' if ok else '否 ❌  ← 扫描器认不出这个文件！')

        if not ok:
            print('    ★ 修正方法：用记事本打开它，在第一行加 #ZIMU# 然后回车，再写正文')
            continue

        # 解码正文
        body = data[6:]
        end = len(body)
        for i, b in enumerate(body):
            if b in (0, 10, 13):
                end = i
                break
        body = body[:end]
        try:
            text = body.decode('utf-8')
            enc = 'UTF-8 ✅'
        except UnicodeDecodeError:
            try:
                text = body.decode('gbk')
                enc = 'GBK（也能认，但建议改成 UTF-8）'
            except Exception:
                text = repr(body)
                enc = '无法识别 ❌'
        print('    正文编码      : %s' % enc)
        print('    正文内容      : %s' % text)
        print('    字符数        : %d' % len(text))

        # 逐字检查字库
        try:
            import re
            cm = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   '..', 'src', 'user_source', 'hdl_source',
                                   'video', 'marquee_cmap.v'),
                      encoding='utf-8').read()
            codes = set(int(m.group(1), 16) for m in
                        re.finditer(r'16.h([0-9A-F]{4});\s*//', cm))
            miss = [c for c in text if ord(c) > 127 and ord(c) not in codes]
            if miss:
                print('    !! 字库缺这些字（会显示成空白）: %s' % ''.join(sorted(set(miss))))
                print('       解决：把它们加进 tools/gen_marquee_font.py 的 CN_CHARS 重新生成')
            else:
                print('    字库覆盖      : 全部命中 ✅')
        except Exception as e:
            print('    (跳过字库检查：%s)' % e)

# ---- 4. 检查图片 ----
print()
print('【第 3 步】广告图片检查')
print('-' * 62)
bmp = [n for n, _ in files if n.upper().endswith('.BMP')]
print('  找到 %d 个 .bmp 文件' % len(bmp))
for name in bmp[:8]:
    p = os.path.join(root, name)
    h = open(p, 'rb').read(54)
    tag = h[:2]
    if tag != b'BM':
        print('    %-30s ❌ 开头不是 "BM"（其实是别的格式改了后缀？）' % name)
        continue
    w, ht = struct.unpack('<ii', h[18:26])
    bpp = struct.unpack('<H', h[28:30])[0]
    ok = (w == 640 and abs(ht) == 480 and bpp == 24)
    print('    %-30s %dx%d %dbit  %s' % (name, w, abs(ht), bpp,
          '✅' if ok else '⚠ 工程只支持 640x480 24bit'))

# ---- 5. 检查音乐 ----
print()
print('【第 4 步】背景音乐检查')
print('-' * 62)
wav = [n for n, _ in files if n.upper().endswith('.WAV')]
if not wav:
    print('  !! 没有 .wav 文件')
for name in wav:
    p = os.path.join(root, name)
    h = open(p, 'rb').read(64)
    if h[:4] != b'RIFF' or h[8:12] != b'WAVE':
        print('    %-30s ❌ 不是标准 WAV' % name)
        continue
    fmt = struct.unpack('<H', h[20:22])[0]
    ch = struct.unpack('<H', h[22:24])[0]
    sr = struct.unpack('<I', h[24:28])[0]
    bps = struct.unpack('<H', h[34:36])[0]
    ok = (fmt == 1 and ch == 2 and sr == 48000 and bps == 16)
    print('    %-24s 格式=%d 声道=%d 采样率=%d 位深=%d  %s'
          % (name, fmt, ch, sr, bps, '✅ 完全合格' if ok else '❌ 需要用 normalize_wav.py 转换'))

print()
print('=' * 62)
print('检查完毕。请把上面全部内容截图发给 Claude。')
print('=' * 62)
