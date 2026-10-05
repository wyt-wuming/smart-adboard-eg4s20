# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 仿真_缩放重载.py
 功能   : 仿真 sd_card_bmp.v 里"缩放值一变就重载当前图 + 400ms 节流"的逻辑
------------------------------------------------------------------------------
 为什么只仿真这部分？
   像素通路已经由 仿真_缩放.py 逐拍验证过了；这里要验证的是**决策逻辑**：
   按键长按连发时会不会疯狂重载（一次装载约 350ms，若每 150ms 重载一次，
   画面会一直卡在装载中）。所以时间刻度取 1ms 就够，不必逐拍。

 与 sd_card_bmp.v 的对应（改 RTL 后请同步改这里）：
   zoom_pending（值变过就置 1，发起重载才清）、
   reload_ok / reload_cnt（距上次重载 ≥400ms 才允许下一次）、
   重载分支条件：scan_done & bmp_ready & display_valid & !load_busy
                 & zoom_pending & reload_ok & img_found_count != 0
==============================================================================
"""

GAP_MS = 400          # 两次重载最小间隔
LOAD_MS = 350         # 一次装载耗时
REPEAT_MS = 150       # 按键长按的连发间隔


def sim(changes, t_end_ms):
    """changes: {时刻ms: 新的缩放值}；返回 [(时刻ms, 缩放值), ...]"""
    z = 100
    zoom_d, pending, ok, cnt = 100, 0, 1, 0
    load_busy, load_end = 0, 0
    issued = []
    for t in range(t_end_ms):
        if t in changes:
            z = changes[t]
        if t == load_end:
            load_busy = 0
        # ---- 与 RTL 同序：① 变化检测 ② 节流计时 ----
        if z != zoom_d:
            pending = 1
        zoom_d = z
        if ok:
            cnt = 0
        elif cnt >= GAP_MS:
            ok = 1
        else:
            cnt += 1
        # ---- 重载分支（要求总线空闲）----
        if (not load_busy) and pending and ok:
            issued.append((t, z))
            pending, ok, cnt = 0, 0, 0
            load_busy, load_end = 1, t + LOAD_MS
    return issued


PASS = []


def case(name, changes, t_end, want_n, want_last=None):
    r = sim(changes, t_end)
    txt = ', '.join('%dms→%d%%' % (t, v) for t, v in r)
    ok_n = (len(r) == want_n) if want_n is not None else True
    ok_v = (want_last is None) or (r and r[-1][1] == want_last)
    print('-' * 70)
    print('  %s' % name)
    print('    重载 %d 次：%s' % (len(r), txt if len(r) <= 10 else txt[:80] + '...'))
    print('    %s  次数符合预期(%s)   %s  最后一次用的是最终值(%s)'
          % ('✅' if ok_n else '❌', want_n, '✅' if ok_v else '❌', want_last))
    PASS.append((name, ok_n and ok_v))
    return r


print('=' * 70)
print('  缩放重载 + 400ms 节流 逻辑仿真（时间刻度 1ms）')
print('=' * 70)
print()

case('场景 1：短按一下（+5%，只变一次）', {50: 105}, 3000, want_n=1, want_last=105)
# 2 秒 / 400ms 间隔 = 5 个间隔 → 最多 6 次重载（首次 + 之后每 400ms 一次）
case('场景 2：长按 2 秒，每 150ms 连发一次（共 13 次变化）',
     {50 + i * REPEAT_MS: 100 + (i + 1) * 5 for i in range(13)}, 6000,
     want_n=6, want_last=165)
case('场景 3：快速连按 3 下（间隔 200ms）',
     {50: 105, 250: 110, 450: 115}, 4000, want_n=None, want_last=115)
case('场景 4：一直按到 200% 再按（回绕到 50%）',
     {50: 195, 300: 200, 550: 50}, 4000, want_n=None, want_last=50)

print()
print('=' * 70)
print('  测试汇总')
print('=' * 70)
for name, ok in PASS:
    print('  %s %s' % ('✅' if ok else '❌', name))
print()
print('  结果: %d/%d 通过' % (sum(1 for _, o in PASS if o), len(PASS)))
print()
print('  对比：若没有节流，场景 2 会触发 13 次重载 x 350ms = 4.55 秒 ——')
print('        而用户只按了 2 秒，画面会一直卡在装载中出不来。')
print('=' * 70)
