# -*- coding: utf-8 -*-
import sys, math
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
"""
==============================================================================
 文件名 : 仿真_音频波形.py
 功能   : 仿真 audio_wave_osd.v 的峰值分段 + 环形缓冲 + 波形绘制逻辑
          （2026-10-22 重做音频可视化：字幕上方的绿色波形图）
------------------------------------------------------------------------------
 与 RTL 的对应：
   ① 瞬时幅度 amp = max(|L|, |R|)（取高 16 位）
   ② 每 128 个 48kHz 采样为一列，波形值 = 段内峰值的高 8 位
   ③ 512 列环形缓冲：第 col 列（0=最左=最旧）读 (wr_ptr + col) & 511
   ④ 绘制：dev = 波形值 >> 4（0~15 像素），|y - 418| <= dev 画绿色
      静音（波形值 0）→ dev=0 → 只画中心 1 像素 → 一条直线
   ⑤ 波形区 x=64~575，中心 y=418；字幕底条从 y=440 起
==============================================================================
"""

SEG_LEN = 128          # 每列采样数
DEPTH   = 512          # 列数
CY      = 418          # 中心线
Y_MIN   = 403          # 波形最高点（dev=15）
Y_MAX   = 433          # 波形最低点
WAVE_X0 = 64
WAVE_X1 = 576
SUB_Y0  = 440          # 字幕底条上沿


class WaveOSD:
    def __init__(self):
        self.ram = [0] * DEPTH
        self.wr = 0
        self.seg_cnt = 0
        self.seg_peak = 0

    def feed(self, amps):
        for a in amps:
            if a > self.seg_peak:
                self.seg_peak = a
            if self.seg_cnt >= SEG_LEN - 1:
                self.seg_cnt = 0
                v = a if a > self.seg_peak else self.seg_peak
                self.ram[self.wr] = v >> 8
                self.seg_peak = 0
                self.wr = (self.wr + 1) & (DEPTH - 1)
            else:
                self.seg_cnt += 1

    def col_value(self, col):
        return self.ram[(self.wr + col) & (DEPTH - 1)]

    def draw_height(self, col):
        """该列亮的像素数 = 2*(wv>>4)+1（0 时是中心 1 像素）"""
        return 2 * (self.col_value(col) >> 4) + 1

    def draw_pixels(self):
        """返回所有亮像素的 (x, y) 坐标（用于检查位置/直线）"""
        px = []
        for col in range(DEPTH):
            d = self.col_value(col) >> 4
            x = WAVE_X0 + col
            for y in range(CY - d, CY + d + 1):
                px.append((x, y))
        return px


PASS = []


def check(name, cond, detail=''):
    PASS.append((name, cond))
    print('  %s %s%s' % ('✅' if cond else '❌', name, ('  ' + detail) if detail else ''))


print('=' * 70)
print('  音频波形显示仿真（峰值分段 + 环形缓冲 + 绘制，512 列）')
print('=' * 70)
print()

# ---------------------------------------------------------------- 场景 1
# 静音 → 每列只有中心 1 像素 → 一条直线（用户明确要求）
w = WaveOSD()
w.feed([0] * (SEG_LEN * DEPTH))
heights = [w.draw_height(c) for c in range(DEPTH)]
check('场景 1：静音 → 所有列为中心 1 像素（一条直线）',
      all(h == 1 for h in heights) and w.col_value(0) == 0)

# ---------------------------------------------------------------- 场景 2
# 满幅 → 每列 31 像素（dev=15）
w = WaveOSD()
w.feed([65535] * (SEG_LEN * DEPTH))
check('场景 2：满幅 → 每列 31 像素（±15）',
      all(w.draw_height(c) == 31 for c in range(DEPTH)),
      '实际 %d' % w.draw_height(0))

# ---------------------------------------------------------------- 场景 3
# 10% 幅度（6553）→ 6553>>8 = 25 → 25>>4 = 1 → 每列 3 像素
w = WaveOSD()
w.feed([6553] * (SEG_LEN * DEPTH))
check('场景 3：10% 幅度 → 每列 3 像素（细波形）',
      w.draw_height(0) == 3, '实际 %d' % w.draw_height(0))

# ---------------------------------------------------------------- 场景 4
# 环形缓冲滚动：喂 600 段，波长递增，检查最右列=最新、最左列=第 89 段
w = WaveOSD()
for seg in range(600):
    w.feed([(seg * 100) & 0xFFFF] * SEG_LEN)   # 每段一个幅度
check('场景 4：滚动 - 最右列 = 第 600 段（最新）',
      w.col_value(511) == ((599 * 100) >> 8) & 0xFF,
      '右列=%d' % w.col_value(511))
check('场景 4b：最左列 = 第 89 段（最旧，已被覆盖判断）',
      w.col_value(0) == ((88 * 100) >> 8) & 0xFF,
      '左列=%d' % w.col_value(0))

# ---------------------------------------------------------------- 场景 5
# 波形位置：所有亮像素 y ∈ [403, 433]，不碰字幕（y ≥ 440）
w = WaveOSD()
w.feed([65535] * (SEG_LEN * 100))
ys = [y for _, y in w.draw_pixels()]
xs = [x for x, _ in w.draw_pixels()]
check('场景 5：波形纵向范围 403~433，不遮挡字幕（440 起）',
      min(ys) == Y_MIN and max(ys) == Y_MAX and max(ys) < SUB_Y0)
check('场景 5b：波形横向范围 64~575（512 列居中）',
      min(xs) == WAVE_X0 and max(xs) == WAVE_X1 - 1)

# ---------------------------------------------------------------- 场景 6
# 音乐段：响 0.5s → 轻 0.5s → 静音 0.5s，每 20ms 采一点的波形示意
print()
print('=' * 70)
print('  波形示意（音乐：响 → 轻 → 静音，512 列压成 80 列打印）')
print('=' * 70)
w = WaveOSD()
RATE = 48000
amps = ([60000] * (RATE // 2) +      # 响 0.5s
        [6000] * (RATE // 2) +       # 轻 0.5s
        [0] * (RATE // 2))           # 静音 0.5s
w.feed(amps)
for band in range(0, DEPTH, 8):      # 每 8 列取最大高度，打印一行
    hs = [w.draw_height(c) for c in range(band, band + 8)]
    level = max(hs) // 2             # 0~15（0 = 静音直线）
    bar = '#' * max(1, level)
    print('  %-15s |%s' % ('', bar))

# ---------------------------------------------------------------- 场景 7
# 峰值检测正确性：段内先小后大 → 取大
w = WaveOSD()
w.feed([1000] * 64 + [60000] * 64)   # 一段内
check('场景 7：段内峰值取最大（先小后大 → 取大）',
      w.col_value(511) == (60000 >> 8), '实际 %d' % w.col_value(511))

# ---------------------------------------------------------------- 场景 8
# 调节模式（I_show=0）→ 波形完全隐藏（与 RTL 的 (I_show && in_wave) 一致）
def lit_with_show(x, y, wv, show):
    if not show:
        return False
    if not (WAVE_X0 <= x < WAVE_X1):
        return False
    return abs(y - CY) <= (wv >> 4)

ok8 = not any(lit_with_show(x, y, 255, False)
              for x in range(WAVE_X0, WAVE_X1, 37)
              for y in range(Y_MIN, Y_MAX + 1))
check('场景 8：调节模式（I_show=0）→ 波形完全隐藏', ok8)

# 运行模式（I_show=1）对照：满幅波形正常显示；静音时中心线仍亮（一条直线）
check('场景 8b：运行模式（I_show=1）→ 波形正常显示（静音时中心线仍亮）',
      lit_with_show(300, CY, 255, True)
      and lit_with_show(300, CY, 0, True)
      and not lit_with_show(300, CY + 5, 0, True))

print()
print('=' * 70)
print('  测试汇总')
print('=' * 70)
for name, ok in PASS:
    print('  %s %s' % ('✅' if ok else '❌', name))
print()
print('  结果: %d/%d 通过' % (sum(1 for _, o in PASS if o), len(PASS)))
print('=' * 70)
