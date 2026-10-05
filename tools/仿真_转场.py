# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 仿真_转场.py
 功能   : 把 video/fade_ctrl.v 的状态机逐拍翻译成 Python 做逻辑仿真
------------------------------------------------------------------------------
 为什么要做这个？
   手上没有板子/仿真器时，把 RTL 的时序逻辑照抄成 Python 是最快的自检手段，
   能抓到"状态机自激死循环""时序算错""alpha 曲线不对"这类光看代码
   看不出来的问题。

 仿真尺度说明：
   真实是逐拍（25MHz，8 秒 = 2 亿拍），Python 跑不动。
   这里改成"1 步 = 1 毫秒"，把 98 个 tick 平摊到 19.6ms（每毫秒 5 个 tick）。
   状态机逻辑、判定条件、先后次序都和 RTL 完全一致，
   只有时间刻度被整体压缩 —— 验证的是"逻辑对不对"，不是"秒表准不准"。
   绝对时间在脚本开头另外用实数算一遍。

 与 fade_ctrl.v 的对应关系（改 RTL 后请同步改这里）：
   PHASE_TICK(98) / TICK_DIV(5102) / FADE_T(32) / STEP_LOG2(1) /
   WAIT_SEC(4) / load_rise 上升沿检测 / F_WAIT 超时
==============================================================================
"""

# ---- 真实参数（和 fade_ctrl.v 一致）----
CLK        = 25_000_000
TICK_DIV   = 5102
STEP_LOG2  = 1
FADE_LOG2  = 5
G_MAX      = 33
PHASE_TICK = 98                    # RAMP_MAX = 33*2 + 32
FADE_T     = 1 << FADE_LOG2        # 32
WAIT_SEC   = 4

# ---- 仿真尺度：1 步 = 1 毫秒 ----
TICKS_PER_MS = PHASE_TICK / 19.6   # = 5.0，因为 98 tick x 5102 拍 / 25MHz = 20ms
TICKS_PER_MS = 5
WAIT_LIMIT   = WAIT_SEC * 1000     # 毫秒

F_IDLE, F_OUT, F_WAIT, F_IN = 0, 1, 2, 3
NAME = {F_IDLE: '空闲', F_OUT: '淡出', F_WAIT: '黑场', F_IN: '淡入'}


def alpha_of(ramp, fstate, g):
    """照抄 RTL 的 alpha 计算：th_start = g<<1，dt 截到 32，alpha = dt<<3"""
    th_start = g << STEP_LOG2
    dt_raw = (ramp - th_start) if ramp > th_start else 0
    dt_cap = FADE_T if dt_raw > FADE_T else dt_raw
    a_cell = (dt_cap & 0x3F) << 3                 # 0 ~ 256
    if fstate == F_IDLE:
        return 256
    if fstate == F_OUT:
        return 256 - a_cell
    if fstate == F_IN:
        return a_cell
    return 0                                       # F_WAIT 全黑


def simulate(load_events, t_end_ms):
    """
    状态机仿真
      load_events: [(起始ms, 持续ms), ...]
      t_end_ms   : 仿真到多少毫秒
    返回 [(ms, 状态, ramp, alpha@屏幕正中, load_busy), ...]（只在变化时记录）
    """
    tick = 0
    ramp = 0
    wait_ms = 0
    busy_d = 0
    fstate = F_IDLE
    out, last = [], None

    for t in range(t_end_ms):
        load_busy = 1 if any(s <= t < s + d for s, d in load_events) else 0
        rise = 1 if (load_busy and not busy_d) else 0
        cur = (fstate, ramp, alpha_of(ramp, fstate, 17), load_busy)
        if cur != last:
            out.append((t, fstate, ramp, cur[2], load_busy))
            last = cur

        # ---- 次态（先算好再统一赋值，模拟非阻塞赋值）----
        n_tick = tick + 1
        fired = n_tick >= TICKS_PER_MS
        if fired:
            n_tick = 0
        n_wait = 0 if fstate != F_WAIT else wait_ms + 1
        n_ramp, n_state = ramp, fstate

        if fstate == F_IDLE:
            n_ramp = 0
            if rise:
                n_state = F_OUT
        elif fstate == F_OUT:
            if ramp >= PHASE_TICK:
                n_state = F_WAIT
            elif fired:
                n_ramp = ramp + 1
        elif fstate == F_WAIT:
            n_ramp = 0
            if (not load_busy) or (wait_ms >= WAIT_LIMIT):
                n_state = F_IN
        elif fstate == F_IN:
            if ramp >= PHASE_TICK:
                n_state = F_IDLE
            elif fired:
                n_ramp = ramp + 1

        tick, ramp, wait_ms, busy_d, fstate = n_tick, n_ramp, n_wait, load_busy, n_state
    return out


def count_out(tr):
    return sum(1 for i in range(1, len(tr)) if tr[i][1] == F_OUT and tr[i - 1][1] != F_OUT)


def show(tr, limit=40):
    n = 0
    for ms, st, rp, a, bz in tr:
        print('    %6d ms  %-4s  ramp=%3d  alpha=%3d  load_busy=%d' % (ms, NAME[st], rp, a, bz))
        n += 1
        if n >= limit:
            print('    ...')
            break


PASS = []

# ===========================================================================
print('=' * 70)
print('  fade_ctrl.v 逻辑仿真（时间尺度：1 步 = 1 毫秒）')
print('=' * 70)
one = PHASE_TICK * TICK_DIV / CLK * 1000
print('  真实参数  : PHASE_TICK=%d  TICK_DIV=%d  FADE_T=%d  WAIT_SEC=%d'
      % (PHASE_TICK, TICK_DIV, FADE_T, WAIT_SEC))
print('  一个方向  : %d tick x %d 拍 = %d 拍 = %.2f ms' % (PHASE_TICK, TICK_DIV, PHASE_TICK * TICK_DIV, one))
print('  淡出+淡入 : %.2f ms   （要求 40ms）%s' % (one * 2, '  ✅' if abs(one*2 - 40) < 0.5 else '  ❌'))
PASS.append(('转场总时长 = 40ms', abs(one * 2 - 40) < 0.5))

# ---------------- 测试 1 ----------------
print()
print('=' * 70)
print('测试 1：正常情况（周期 5 秒，装载 350ms）')
print('=' * 70)
tr = simulate([(1000, 350)], 1500)
show(tr, 12)
seq = [NAME[st] for _, st, _, _, _ in tr]
ok = '空闲' in seq and '淡出' in seq and '黑场' in seq and '淡入' in seq
print('  状态序列 : %s  %s' % (' → '.join(seq), '✅' if ok else '❌'))
PASS.append(('正常换场四阶段齐全', ok))

# ---------------- 测试 2：关键回归 ----------------
print()
print('=' * 70)
print('测试 2：★ 周期 1 秒（原来是"爆掉"的场景）')
print('=' * 70)
ev = [(i * 1000, 350) for i in range(1, 6)]
tr = simulate(ev, 6000)
n = count_out(tr)
print('  6 秒 / 5 次装载 → 淡出触发 %d 次  %s' % (n, '✅ 没有自激' if n == 5 else '❌ 自激了！'))
PASS.append(('周期 1 秒时不自激（5 次装载触发 5 次）', n == 5))
show(tr, 30)

# ---------------- 测试 3 ----------------
print()
print('=' * 70)
print('测试 3：装载(1.2s) 比周期(1s) 还长')
print('=' * 70)
ev = [(1000, 1200), (2600, 1200)]
tr = simulate(ev, 5000)
n = count_out(tr)
print('  5 秒 / 2 次装载 → 淡出触发 %d 次  %s' % (n, '✅ 没有自激' if n == 2 else '❌ 自激了！'))
PASS.append(('装载比周期长时不自激', n == 2))

# ---------------- 测试 4 ----------------
print()
print('=' * 70)
print('测试 4：★ 装载卡死（load_busy 一直不拉低）—— 超时保护')
print('=' * 70)
tr = simulate([(500, 999999)], 6000)
esc = [ms for ms, st, _, _, _ in tr if st == F_IN]
print('  4 秒超时后强制进入淡入 : %s' % ('✅ 是（第 %d ms）' % esc[0] if esc else '❌ 没有，永久黑屏！'))
PASS.append(('装载卡死时 4 秒超时脱困', bool(esc)))
show(tr, 10)

# ---------------- 测试 5 ----------------
print()
print('=' * 70)
print('测试 5：alpha 曲线 + 栅格对角线顺序')
print('=' * 70)
tr = simulate([(0, 350)], 60)
print('   时间(ms)   g=0    g=17   g=33     (256=全亮, 0=全黑)')
for t_ms in range(0, 45, 4):
    rec = None
    for ms, st, rp, _, _ in tr:
        if ms <= t_ms:
            rec = (st, rp)
    if rec:
        st, rp = rec
        print('    %5d     %4d   %4d   %4d' % (t_ms, alpha_of(rp, st, 0), alpha_of(rp, st, 17), alpha_of(rp, st, 33)))

g0 = [alpha_of(rp, st, 0) for _, st, rp, _, _ in tr]
g33 = [alpha_of(rp, st, 33) for _, st, rp, _, _ in tr]
fs = lambda g: next((i for i, v in enumerate(g) if v < 256), None)
f0, f33 = fs(g0), fs(g33)
print()
print('  g=0 （左上角）开始变暗于第 %s 个采样点' % f0)
print('  g=33（右下角）开始变暗于第 %s 个采样点' % f33)
ok = (f0 is not None) and (f33 is not None) and f0 < f33
print('  对角线顺序 : %s' % ('✅ 左上先暗，右下后暗' if ok else '❌ 顺序错误'))
PASS.append(('栅格按对角线依次变暗', ok))

amin = min(a for _, _, _, a, _ in tr)
amax = max(a for _, _, _, a, _ in tr)
print('  alpha 范围 : %d ~ %d  %s' % (amin, amax, '✅ 能达到全黑' if amin == 0 else '❌ 没到全黑'))

# ===========================================================================
print()
print('=' * 70)
print('  测试汇总')
print('=' * 70)
for name, ok in PASS:
    print('  %s  %s' % ('✅' if ok else '❌', name))
print()
print('  结果: %d/%d 通过' % (sum(1 for _, o in PASS if o), len(PASS)))
print('=' * 70)
