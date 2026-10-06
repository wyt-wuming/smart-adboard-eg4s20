# -*- coding: utf-8 -*-
import sys
# Windows 控制台默认 GBK，强制 UTF-8 输出，否则 ✅/❌ 会 UnicodeEncodeError
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
"""
==============================================================================
 文件名 : 仿真_缩放跳跃.py
 功能   : 逐拍仿真 sd_card_bmp.v 的"缩放重载决策逻辑"
          （★ 含 500ms 静默期 + 800ms 强制刷新兜底，即 2026-10-06 修复后的当前 RTL）
          排查现象："按住连按几十下 → 画面卡住不动 → 数码管位5=1（空闲）→
                    等很久才到达目标缩放大小"
------------------------------------------------------------------------------
 与 sd_card_bmp.v 的对应（改 RTL 后请同步改这里）：
   ① 变化检测  ：I_zoom_pct != zoom_d → zoom_pending=1、zoom_quiet=0
   ② 静默计时  ：数值稳定时 zoom_quiet 递增，满 500ms 才允许重载
   ③ 强制兜底  ：zoom_force_cnt 随 pending 持续计时（连按不清零），
                  满 800ms 还没重载就强制刷一次
   ④ 节流门闩  ：reload_ok，发起重载后 400ms 内不允许再重载
   ⑤ 重载分支  ：scan_done & bmp_ready & display_valid & !load_busy
                  & zoom_pending & reload_ok
                  & (zoom_quiet>=500ms || zoom_force_cnt>=800ms)
                  & img_found_count != 0
   ⑥ 装载耗时  ：350ms（一次 BMP 装载，期间 bmp_ready=0）

 不建模的部分（对结论无影响，注明）：
   - cfg_cdc 跨时钟域延迟 <1us，相对 150ms 连发间隔可忽略；
   - 数码管位5 由顶层按状态编码显示：空闲=1、装载中=4；
     这里用 load_busy 推演：空闲时长占比 = 位5 显示 1 的时间占比。

 时间刻度 1ms（所有决策参数都是 ms 级，无逐拍时序细节）。
==============================================================================
"""

GAP_MS = 400          # 两次重载最小间隔（RELOAD_GAP，@100MHz = 40M 拍）
QUIET_MS = 500        # 缩放值静默期（ZOOM_QUIET_GAP = 50M 拍）
FORCE_MS = 800        # 连按强制刷新兜底（ZOOM_FORCE_GAP = 80M 拍）
LOAD_MS = 350         # 一次 BMP 装载耗时（实测约 350ms）
REPEAT_MS = 150       # 按键长按连发间隔（key_press_event REPEAT_MS）
STEP_PCT = 5          # 每按一下缩放变化 ±5%（key_ctrl_fsm ZOOM_STEP）


def sim(changes, t_end_ms, quiet_enable=True, force_gap_ms=FORCE_MS):
    """changes: {时刻ms: 新的缩放值}。返回 (重载列表, 空闲ms数)。

    quiet_enable=False  → 旧行为（加静默期之前，无静默无兜底）；
    force_gap_ms =None → 2026-10-06 中间版（只有 500ms 静默，只挡不兜）；
    force_gap_ms =数值 → 当前 RTL（静默 + 强制刷新兜底）。
    """
    z = 100
    zoom_d, pending, quiet, ok, cnt = 100, 0, 0, 1, 0
    fcnt = 0               # 候选修复：zoom_pending 已持续的时长（不受 quiet 清零影响）
    load_busy, load_end = 0, 0
    issued = []           # [(发起时刻ms, 发起时缩放值)]
    idle_ms = 0           # load_busy=0 的毫秒数 → 位5 显示 1 的时长
    for t in range(t_end_ms):
        if t in changes:
            z = changes[t]
        if t == load_end:
            load_busy = 0
        # ---- ① 变化检测 + 静默计时（与 RTL 同序）----
        if z != zoom_d:
            pending, quiet = 1, 0
        elif quiet < QUIET_MS:
            quiet += 1
        zoom_d = z
        # ---- ①b 候选修复：强制刷新计时（pending 持续计时，连按不清零）----
        if force_gap_ms is not None:
            if pending:
                fcnt = fcnt + 1 if fcnt < force_gap_ms else fcnt
            else:
                fcnt = 0
        # ---- ② 节流门闩 reload_ok ----
        if ok:
            cnt = 0
        elif cnt >= GAP_MS:
            ok = 1
        else:
            cnt += 1
        # ---- ③ 重载分支（scan_done/bmp_ready/display_valid 恒真，
        #      img_found_count!=0；装载期间 load_busy=1 已挡掉）----
        cond = (not load_busy) and pending and ok
        if quiet_enable:
            cond = cond and (quiet >= QUIET_MS)
        if force_gap_ms is not None and quiet_enable:
            cond = (not load_busy) and pending and ok \
                and (quiet >= QUIET_MS or fcnt >= force_gap_ms)
        if cond:
            issued.append((t, z))
            pending, ok, cnt = 0, 0, 0
            load_busy, load_end = 1, t + LOAD_MS
        # ---- ④ 空闲统计 ----
        if not load_busy:
            idle_ms += 1
    return issued, idle_ms


def paint_trace(changes, issued, t_end_ms, sample_every=500):
    """把"屏幕实际显示的缩放值"按时间画成文本曲线（重载完成才更新画面）。"""
    # 先算每次重载完成时刻 → 画面值
    commits = {}
    for t, v in issued:
        commits[t + LOAD_MS] = v
    disp = 100
    line = []
    for t in range(t_end_ms):
        if t in commits:
            disp = commits[t]
        line.append(disp)
    # 降采样画图
    print('    屏幕显示的缩放值（每 500ms 一点，* = 该点画面值）：')
    maxv = max(line) + 5
    for t in range(0, t_end_ms, sample_every):
        v = line[t]
        bar = '#' * int(20 * (v - 50) / (maxv - 50))
        mark = '*' if (t in commits or t == 0) else ' '
        print('      t=%5dms %s%3d%% %s' % (t, mark, v, bar))


PASS = []


def case(name, changes, t_end, want_n, want_last, idle_hold_ge_ms=0,
         idle_hold_desc='', want_mid=None, max_gap_ms=None):
    r, idle = sim(changes, t_end)
    txt = ', '.join('%dms→%d%%' % (t, v) for t, v in r)
    ok_n = (len(r) == want_n) if want_n is not None else True
    ok_v = (want_last is None) or (r and r[-1][1] == want_last)
    ok_mid = (want_mid is None) or (want_mid == [v for _, v in r])
    ok_idle = True
    if idle_hold_ge_ms:
        # 验证"卡住"期间系统保持空闲：找连续无重载且无装载的最长窗口
        busy = []
        for t, _ in r:
            busy += list(range(t, t + LOAD_MS))
        longest = cur = 0
        for t in range(t_end):
            cur = cur + 1 if t not in busy else 0
            longest = max(longest, cur)
        ok_idle = longest >= idle_hold_ge_ms
    ok_gap = True
    if max_gap_ms is not None:
        # 验证"跟手"：从第一次按键起，画面两次刷新之间的最长间隔
        commits = [t + LOAD_MS for t, _ in r]
        gaps = [commits[0] - min(changes)] + \
               [b - a for a, b in zip(commits, commits[1:])]
        ok_gap = bool(gaps) and (max(gaps) <= max_gap_ms)
    print('-' * 70)
    print('  %s' % name)
    print('    重载 %d 次：%s' % (len(r), txt if len(r) <= 10 else txt[:90] + '...'))
    print('    空闲占比 %d%%（推演数码管位5：空闲=1）' % (100 * idle // t_end))
    print('    %s 次数符合预期(%s)  %s 最终画面值是目标(%s)'
          % ('✅' if ok_n else '❌', want_n, '✅' if ok_v else '❌', want_last))
    if idle_hold_ge_ms:
        print('    %s 按住期间连续空闲 ≥ %dms（%s）'
              % ('✅' if ok_idle else '❌', idle_hold_ge_ms, idle_hold_desc))
    if max_gap_ms is not None:
        print('    %s 画面刷新间隔 ≤ %dms（跟手，不死卡）'
              % ('✅' if ok_gap else '❌', max_gap_ms))
    if want_mid is not None:
        print('    %s 画面经历序列符合预期(%s)'
              % ('✅' if ok_mid else '❌', want_mid))
    PASS.append((name, ok_n and ok_v and ok_idle and ok_mid and ok_gap))
    return r


print('=' * 70)
print('  缩放重载决策逻辑仿真（★ 含 500ms 静默期 + 800ms 强制刷新兜底）')
print('  时间刻度 1ms；对应 2026-10-06 修复后的 sd_card_bmp.v')
print('=' * 70)
print()

# ---------------------------------------------------------------- 场景 1
# 原 bug 场景：按住 4.5 秒（每 150ms 连发一次，100%→200% 共 20 下），松手
# 修复后：按住期间强制刷新兜底 → 画面每约 1.15s 跟一档，松手 ≤850ms 到位
s1 = {1000 + i * REPEAT_MS: 100 + (i + 1) * STEP_PCT for i in range(20)}
case('场景 1：按住 4.5s 连按 20 下（100%→200%），修复后画面跟手',
     s1, 12000, want_n=4, want_last=200,
     want_mid=[130, 160, 190, 200], max_gap_ms=1200)

# ---------------------------------------------------------------- 场景 2
# 小步长对照：按一下停 3 秒，共 3 下 → 每次都跟手重载
case('场景 2（对照）：小步长，按一下停 3 秒 ×3 下（105/110/115）',
     {1000: 105, 4000: 110, 7000: 115}, 10000, want_n=3, want_last=115)

# ---------------------------------------------------------------- 场景 3
# 中途停顿：按住 8 下 → 停 700ms → 再按住 8 下 → 松手
# 修复后：第一轮按住时 800ms 兜底刷一次中间值(130)，停顿期静默刷 140，
#         第二轮再兜底刷 170，松手后静默刷 180。画面经历 100→130→140→170→180。
s3 = {1000 + i * REPEAT_MS: 100 + (i + 1) * STEP_PCT for i in range(8)}
s3.update({3250 + i * REPEAT_MS: 140 + (i + 1) * STEP_PCT for i in range(8)})
case('场景 3：按住 8 下(→140) → 停 700ms → 按住 8 下(→180) → 松手',
     s3, 8000, want_n=4, want_last=180, want_mid=[130, 140, 170, 180])

# ---------------------------------------------------------------- 场景 4
# 装载期间又按：重载发起后 200ms（装载 350ms 还没完）再按一下
# 预期：第 1 次重载完成（画面 105）后，再等 500ms 静默，第 2 次重载 → 110
case('场景 4：重载进行到一半（200ms）时又按一下',
     {1000: 105, 1700: 110}, 5000, want_n=2, want_last=110, want_mid=[105, 110])

# ---------------------------------------------------------------- 场景 5
# 大步长单次跳变（排除"采到旧值"）：200% 回绕到 50%，一次跳 150%
# 重载发起时值已静默 500ms，img_scaler 采样必为新值 → 画面最终 50%
case('场景 5：单次大跳变 200%→50%（回绕），方向B排除证据',
     {1000: 50}, 4000, want_n=1, want_last=50)

print()
print('=' * 70)
print('  场景 1 画面变化过程（修复后：跟手慢半拍，不死卡）')
print('=' * 70)
r1, _ = sim(s1, 12000)
paint_trace(s1, r1, 12000)

print()
print('=' * 70)
print('  对照：三个版本的场景 1 行为')
print('=' * 70)
r_none, _ = sim(s1, 12000, quiet_enable=False)     # 版本 A：加静默期之前
r_quiet, _ = sim(s1, 12000, force_gap_ms=None)     # 版本 B：只挡不兜（本次排查的 bug）
r_fix, _ = sim(s1, 12000)                          # 版本 C：当前 RTL（静默+兜底）
print('  版本 A 无静默（最早）      ：%d 次重载，装载总耗时 %dms —— 按住 4500ms 里疯狂重载'
      % (len(r_none), len(r_none) * LOAD_MS))
print('  版本 B 只挡不兜（2026-10-06 初版静默）：%d 次重载 —— 按住期间画面死卡 4.5s'
      % len(r_quiet))
print('  版本 C 静默+800ms 兜底（当前 RTL）：%d 次重载：%s'
      % (len(r_fix), ', '.join('%dms→%d%%' % (t, v) for t, v in r_fix)))
print('  → C 按住期间画面每约 1.15s 跟一档，松手后 ≤850ms 到达精确目标。')
print()

print('=' * 70)
print('  测试汇总')
print('=' * 70)
for name, ok in PASS:
    print('  %s %s' % ('✅' if ok else '❌', name))
print()
print('  结果: %d/%d 通过' % (sum(1 for _, o in PASS if o), len(PASS)))
print('=' * 70)
