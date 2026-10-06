# B 方案（SD 多块读提速）—— 设计与交接文档

> **用途**：这是给下一个会话（新话题）的交接文档。
> 读完这一份，配合 `doc/项目完整交接文档.md` 和 `doc/代码结构说明.md`，就能直接开工做 B。
> **最后更新：2026-10-06**

---

## 一、现在要解决什么

**用户痛点**：调整画面缩放后，要等 **3~4 秒**画面才变（连按时更久）。

**目标**：把"重新读一遍源图"的时间从 **约 3.6 秒压到 0.5 秒左右**。

**已验证的因果关系**（本轮实测确认）：
- 不是死锁——**等到最后总能到达目标尺寸**；
- 不是被其他通道长期抢占——仲裁优先级已经是"图片优先于字幕"；
- **真因是 SD 卡"每读一个扇区都要重新发一次命令"**：

| 环节 | 耗时 |
|---|---|
| SPI 传输 512 字节 @25MHz | 164 µs |
| **SD 卡响应命令 + 内部定位扇区** | **约 1 ms** ← 元凶 |
| 合计 | **约 1.2 ms / 扇区** |

一张 640×480 的 BMP = 921654 字节 = **1800 个扇区** → 纯命令延迟约 2.2 秒，
再叠加音频播放对总线的占用 → **3~4 秒**。

**解法**：用 **CMD18（READ_MULTIPLE_BLOCK）** 一次命令连续读多个扇区，
卡只定位一次 → 那 1 ms 的延迟被摊薄掉。

---

## 二、B 要改的 4 个模块

### 数据通路现状

```
bmp_read ──sd_sec_read(电平) + sd_sec_read_addr──┐
wav_read ──同──┤                                  ├─→ sd_bus_arbiter ─→ sd_card_top ─→ sd_card_sec_read_write ─→ spi_master
txt_read ──同──┘                                  │      （每扇区仲裁一次）        （每扇区一次 CMD17）
                                                  │
        ←── sd_sec_read_data / _data_valid / _end ─┘   ★ 这一层接口 **不需要动**
```

**★ 好消息**：字节级数据接口（`block_read_valid` / `block_read_data`）保持不变，
所以 `spi_master` 和 `sd_card_top` 的数据路径**不用改**。

### 改动清单

| # | 文件 | 改什么 |
|---|---|---|
| 1 | `SD/sd_card_sec_read_write.v` | 加输入 `I_burst_len[7:0]`（1=单块，N=多块）。>1 时走 **CMD18**，连续收 N 个扇区后发 **CMD12** 停止 |
| 2 | `SD/sd_card_top.v` | 把 `I_burst_len` 透传给 `sd_card_sec_read_write` |
| 3 | `SD/sd_bus_arbiter.v` | 加输入"本次请求的 burst 长度"；授权时**整段授权**（授权期间不换通道）|
| 4 | `SD/bmp_read.v` | `ST_LOAD_DATA` 改成"一次请求 8 个扇区"，内部按扇区计数 |
| — | `top_tf_hdmi_audio.v` | 给 bmp 通道接上 burst 参数（wav/txt 传 1，保持单块）|

### 关键设计约束

| 约束 | 原因 |
|---|---|
| **只给图片通道用多块读** | 音频/字幕保持单块，实时性完全不受影响 |
| **一次最多 8 个扇区** | 约 2ms 占用总线；音频 FIFO 有约 10ms 余量，扛得住 |
| **wav/txt 的 `burst_len` 固定传 1** | 它们的请求逻辑不用改 |
| **CMD18 之后必须发 CMD12** | SD 规范要求，否则卡会一直等后续数据 |

---

## 三、实现要点（给下个会话的具体提示）

### 1. `sd_card_sec_read_write.v`

现有状态机：`S_IDLE → S_CMD0 → S_CMD8 → S_CMD55 → S_CMD41 → S_CMD16 → S_WAIT_READ_WRITE`
读写：`S_WAIT_READ_WRITE → S_CMD17 → S_READ → S_READ_END → S_WAIT_READ_WRITE`

**建议新增**：
- `S_CMD18`：发多块读命令（`CMD18` 的 CRC 与 CMD17 相同：`8'hff` 那一字节用法一致，注意命令字节是 `8'd18`）
- `S_READ_MULTI`：连续接收，用一个 `sec_cnt` 数已收扇区数
- `S_CMD12`：N 个扇区收完后发停止命令
- **`sd_sec_read_end` 只在"整段读完"时拉高一次**（现在的语义是"一个扇区读完"，要改成"本次请求完成"）

⚠️ **注意**：`S_READ` 现在的 `block_read_req` / `block_read_req_ack` 握手是**每个扇区一次**，
改成多块后要**每个扇区仍然走一次这个握手**（因为 spi_master 是按块收的），
只是不再重发 CMD17。

### 2. `sd_bus_arbiter.v`

现在的 `pick` 是每拍重新仲裁（组合逻辑）。改成：
- 加 `req_burst_len`（来自各通道）
- 授权时锁存 `grant_burst_left`，**归零前不重新仲裁**
- 这样一次授权就跑完 8 个扇区

⚠️ 音频的 `wav_urgent` 依然最高——但由于一次最多挡 2ms，不会断音。

### 3. `bmp_read.v`

`ST_LOAD_DATA` 现在是"读一个扇区 → `sd_sec_read_addr + 1` → 再读"。
改成"一次请求 8 个扇区，收满后地址 +8"。
`bmp_len_cnt >= file_len` 的结束判断逻辑**不用改**（它按字节计数）。

---

## 四、验证方法

| 步骤 | 做什么 |
|---|---|
| 1 | **静态检查**（保留字 / 配对 / 未命名块 / 先用后声明 / 例化端口核对）——用本文件末尾的脚本 |
| 2 | **写一个 SD 命令序列的逐拍仿真**（Python）：模拟 CMD18 + CMD12 的时序，确认状态机能正确收完 N 个扇区并回到 `S_WAIT_READ_WRITE` |
| 3 | 上板：调缩放，测量"松手 → 画面变化"的时间，目标 **< 1 秒** |
| 4 | **回归**：音乐、字幕、切图、自动轮播都必须正常（重点听音乐有没有"滋滋"声——那说明音频被饿到了）|

**如果音乐出现杂音** → 把 burst 从 8 降到 4（占用时间减半）。

---

## 五、本轮（2026-10-06）已经完成的改动

### 修复的真实 bug

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 图、音乐、字幕全没有 | `bmp_read` 的 `O_frame_start` 判断写成 `== pixel_offset`，实际应是 `pixel_offset + 3`（像素 3 字节拼装）→ 条件永不成立 → img_scaler 卡死 | 改成 `pixel_offset + 32'd3` |
| 2 | 画面横条纹花屏 + 不能切图 | img_scaler 突发输出（640 拍连发）超过写 FIFO 深度 512 → 溢出丢像素 | S_EMIT 加 4 分频（`EMIT_DIV=3`）|
| 3 | 第 5 张图永远显示不出来 | `next_from_current` 声明成 2 位，而 `next_index_limited()` 返回 3 位 → 索引 4~7 被截断 | 改成 3 位 |
| 4 | 复位后有时有图有时没图（随机）| `O_frame_start` 只有 1 拍宽，可能被错过 | 拉长成 8 拍电平（**注意上限：必须远小于源像素间隔 106 拍**，曾误设 255 拍导致写指针被钉住）|
| 5 | 长按多次后黑屏卡死、数码管变 0 | `rst_all` 里的 `audio_pll_lock` 和 `rst_n` 都没有滤波 → 电源噪声被当成复位 | `rst_n` 加 20ms 消抖、PLL lock 加 1ms 滤波 |
| 6 | 调整缩放后要等很久 | 见本文档第一节 | ⬜ **本次要做（B）** |

### 交互优化

| 改动 | 效果 |
|---|---|
| **静默重载**：缩放值变化后等 500ms 无新变化才重载 | 连按 10 次从"等 36 秒"降到"等 4 秒" |
| **扫描范围 16MB → 64MB（改回来了）** | 曾缩到 16MB 提速，结果 23.8MB 的 WAV 文件头不在范围内 → **没声音**。教训：扫描范围必须覆盖文件头可能出现的最远位置 |
| **装载超时 2.7 秒 → 30 秒** | 2.7 秒比实际装载时间（3.6 秒）还短 → 超时打断自己的装载 → 无限循环 |
| **SD 初始化加 100ms 上电等待** | SD 规范要求上电稳定 ≥1ms 才能收命令 |

### 关键约束（**不要违反**）

| 约束 | 说明 |
|---|---|
| **WAV 必须 48000Hz / 16bit / 立体声 / PCM** | HDMI 音频时钟（ACR）决定的，改任何一项都会变调或爆音 |
| **扫描范围不能小于 64MB** | 大文件（24MB 的 WAV）的文件头可能落在很后面 |
| **BRAM 余量极紧（约 62/64 块）** | 不要再加块 RAM |
| **视频流水线每插一级都要补 `video_sync_delay`** | 否则画面偏移 |
| **信号必须声明在第一次使用之前** | HDL-7225 隐式线网坑 |

---

## 六、下次开工的第一句话

> 读 `doc/B方案_多块读_设计与交接.md`，按第二节的 4 个模块改造 SD 通路支持多块读（CMD18 + CMD12），
> 只给图片通道用、一次最多 8 个扇区，音频/字幕保持单块。改完先跑静态检查和 Python 逐拍仿真，再告诉我可以编译。

---

## 七、常用静态检查脚本（复制即用）

```python
# -*- coding: utf-8 -*-
"""静态检查五项：保留字 / 配对 / 未命名块声明 / 先用后声明 / 例化端口核对"""
import io, re, glob, os
BS = chr(92); ROOT = 'src/user_source/hdl_source'
SKIP = {'SD/sdram.v'}          # 参考例程，含 `ifdef SIMULATION 条件编译，跳过
files = [f for f in glob.glob(ROOT+'/**/*.v', recursive=True) if not f.endswith('.enc.v')]
def relf(f): return os.path.relpath(f, ROOT).replace(BS, '/')
def sc(s):
    s = re.sub(r'//[^\n]*', '', s)
    return re.sub(r'/\*.*?\*/', '', s, flags=re.S)
KW = set('buf not and or xor nand nor xnor tran time event wait'.split())
p = []
# ① 保留字（只在"标识符位置"查，always @(posedge a or posedge b) 里的 or 合法）
for f in files:
    rel = relf(f); c = sc(io.open(f, encoding='utf-8', errors='ignore').read())
    for m in re.finditer(r'\b(?:input|output|inout|reg|wire|integer|parameter|localparam)\b[^;,=\n]*?\b(\w+)\s*(?=[,;=)\n])', c):
        if m.group(1) in KW: p.append('① %s 保留字做声明名 %s' % (rel, m.group(1)))
    for m in re.finditer(r'(?:^|\n)\s*(\w+)\s*(?:<=|=)(?!=)', c):
        if m.group(1) in KW: p.append('① %s 保留字做赋值目标 %s' % (rel, m.group(1)))
# ② 配对
for f in files:
    rel = relf(f); c = sc(io.open(f, encoding='utf-8', errors='ignore').read())
    for name, a, b in (('begin/end', r'\bbegin\b', r'\bend\b'),
                       ('module', r'^\s*module\b', r'\bendmodule\b'),
                       ('case', r'\bcase[xz]?\s*\(', r'\bendcase\b')):
        na, nb = len(re.findall(a, c, re.M)), len(re.findall(b, c))
        if na != nb: p.append('② %s %s %d/%d' % (rel, name, na, nb))
# ③ 未命名块内声明变量（HDL-8007）
for f in files:
    rel = relf(f)
    lines = sc(io.open(f, encoding='utf-8', errors='ignore').read()).split('\n')
    for i, ln in enumerate(lines):
        for m in re.finditer(r'\bbegin\b(?!\s*:)', ln):
            j, buf, k = i, ln[m.end():], 0
            while k < 6 and not buf.strip():
                j += 1; k += 1; buf = lines[j] if j < len(lines) else ''
            if re.match(r'\s*(reg|wire|integer|real|time)\b', buf):
                p.append('③ %s:%d 未命名块内声明' % (rel, j+1))
# ④ 先用后声明（HDL-7225）—— 注意排除 1'b0 里的 b0
for f in files:
    rel = relf(f)
    if rel in SKIP: continue
    c = sc(io.open(f, encoding='utf-8', errors='ignore').read())
    for mb in re.finditer(r'\bmodule\s+(\w+).*?\bendmodule\b', c, re.S):
        mc = mb.group(0); decl = {}
        for m in re.finditer(r'\b(?:reg|wire|integer)\b[^;,()=\n]*?\b(\w+)\s*(?=[,;=)\n])', mc):
            decl.setdefault(m.group(1), mc[:m.start()].count('\n')+1)
        for m in re.finditer(r"(?<![\w\$.'])([a-zA-Z_]\w*)(?!\s*')(?!\s*\()", mc):
            n = m.group(1)
            if n in decl and mc[:m.start()].count('\n')+1 < decl[n]:
                p.append('④ %s(%s) %s 先用后声明' % (rel, mb.group(1), n)); break
# ⑤ 例化端口核对
modports = {}
for f in files:
    c = sc(io.open(f, encoding='utf-8', errors='ignore').read())
    for m in re.finditer(r'\bmodule\s+(\w+)\s*(?:#\s*\(.*?\)\s*)?\((.*?)\)\s*;', c, re.S):
        ps = set()
        for seg in re.split(r',', m.group(2)):
            w = re.findall(r'\b(\w+)\b', re.sub(r'\[[^\]]*\]', '', seg))
            if w: ps.add(w[-1])
        modports[m.group(1)] = ps
for f in files:
    rel = relf(f); c = sc(io.open(f, encoding='utf-8', errors='ignore').read())
    for m in re.finditer(r'([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?(\w+)\s*\(', c):
        mod = m.group(1)
        if mod not in modports or mod in ('module','if','for','case','while','assign','always'): continue
        if re.search(r'\bmodule\s*$', c[max(0, m.start()-20):m.start()]): continue
        i = c.find('(', m.end()-1); depth = 0; j = i
        while j < len(c):
            if c[j] == '(': depth += 1
            elif c[j] == ')':
                depth -= 1
                if depth == 0: break
            j += 1
        bad = set(re.findall(r'\.\s*(\w+)\s*\(', c[i:j+1])) - modports[mod]
        if bad: p.append('⑤ %s 例化 %s 端口错误 %s' % (rel, mod, ','.join(sorted(bad))))
print('=== 静态检查 ===')
print('  ✅ 五项全部通过' if not p else '')
for x in p: print('  ❌ ' + x)
print('问题数 =', len(p))
```

**注意**：脚本里处理路径用 `chr(92)` 代替 `'\\'`（在 heredoc 里反斜杠会被 shell 吃掉）。
