# -*- coding: utf-8 -*-
import sys
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
"""
==============================================================================
 文件名 : 仿真_转场触发.py
 功能   : 逐拍仿真 fade_ctrl.v 的转场触发逻辑（2026-10-06 修复后）
          验证："换图"才转场；"缩放重载"（同一张图换比例）不转场、画面不黑。
------------------------------------------------------------------------------
 修复内容：转场触发条件从"load_busy 上升沿"改为"img_switch 上升沿"
           （img_switch = load_busy && load_idx != img_idx）。
 上板 bug：连续缩放重载节奏（约 450ms）比转场全程（周期 5s 时 600ms）还短，
           旧逻辑每次重载都触发"淡出→黑场→淡入"→ 画面不停黑屏。
------------------------------------------------------------------------------
 模型（与 fade_ctrl.v 对应，时间刻度 1ms）：
   F_IDLE：正常显示；img_switch 上升沿 → F_OUT（旧逻辑：load_busy 上升沿）
   F_OUT ：淡出 250ms（周期 5s 时 = 98 tick x 周期 x 50ms/周期）→ F_WAIT
   F_WAIT：全黑，等 load_busy 变低（上限 4s 防卡死）→ F_IN
   F_IN  ：淡入 250ms → F_IDLE
   转场期间画面按 alpha 渐变；简化判定：F_WAIT=全黑、F_OUT/F_IN=半黑过程。
==============================================================================
"""

OUT_MS   = 250          # 淡出时长（周期 5s 时）
IN_MS    = 250          # 淡入时长
WAIT_MAX = 4000         # 黑场等待上限（4 秒，防装载卡死）
LOAD_MS  = 350          # 一次装载
GAP_MS   = 100          # 连续重载之间的 load_busy 低电平间隙


def sim(t_end_ms, events, use_img_switch=True):
    """events: {时刻ms: (load_busy, img_switch)}，之后按电平保持到下一次变化。
    返回 (黑屏毫秒数, 转场次数, 状态历史采样)"""
    fstate = 'IDLE'      # IDLE / OUT / WAIT / IN
    st_left = 0          # 当前状态剩余 ms
    lb, sw = 0, 0
    wait_cnt = 0
    black_ms, n_trans = 0, 0
    hist = []
    tlist = sorted(events) + [t_end_ms]
    ei = 0
    for t in range(t_end_ms):
        if ei < len(tlist) and t == tlist[ei]:
            lb, sw = events[t]
            ei += 1
        # ---- 触发判断（在 IDLE 时看上升沿）----
        if fstate == 'IDLE':
            trigger = sw if use_img_switch else lb
            if trigger:
                n_trans += 1
                fstate, st_left = 'OUT', OUT_MS
        # ---- 状态推进 ----
        if fstate == 'OUT':
            st_left -= 1
            if st_left <= 0:
                fstate, st_left, wait_cnt = 'WAIT', 0, 0
        elif fstate == 'WAIT':
            wait_cnt += 1
            if not lb or wait_cnt >= WAIT_MAX:
                fstate, st_left = 'IN', IN_MS
        elif fstate == 'IN':
            st_left -= 1
            if st_left <= 0:
                fstate = 'IDLE'
        # ---- 统计 ----
        if fstate == 'WAIT':
            black_ms += 1
        hist.append(fstate)
    return black_ms, n_trans, hist


def summary(black_ms, n_trans, t_end, hist, label):
    # 黑屏占比 + 最长连续黑屏
    longest = cur = 0
    for s in hist:
        cur = cur + 1 if s == 'WAIT' else 0
        longest = max(longest, cur)
    print('  %s' % label)
    print('    转场次数 = %d，黑屏合计 = %dms（占 %d%%），最长连续黑屏 = %dms'
          % (n_trans, black_ms, 100 * black_ms // t_end, longest))
    return (black_ms, longest)


PASS = []

print('=' * 70)
print('  转场触发逻辑仿真（fade_ctrl 修复后，时间刻度 1ms）')
print('=' * 70)
print()

# ---------------------------------------------------------------- 场景 1
# 换图装载（切图/轮播）：应该正常转场
ev1 = {1000: (1, 1), 1350: (0, 0)}
b, n, h = sim(4000, ev1, True)
ok = (n == 1) and (b > 0)
summary(b, n, 4000, h, '场景 1：换图一次（img_switch=1）→ 转场完整走一遍')
PASS.append(('场景 1', ok))
print('    %s 转场 1 次且经过黑场' % ('✅' if ok else '❌'))
print()

# ---------------------------------------------------------------- 场景 2
# ★ 本次修复核心：连续缩放重载（load_busy 脉动，img_switch 恒 0）
#   修复后：永不转场、画面永不黑
ev2 = {}
for i in range(8):
    ev2[1000 + i * (LOAD_MS + GAP_MS)] = (1, 0)      # 装载开始（缩放重载）
    ev2[1000 + i * (LOAD_MS + GAP_MS) + LOAD_MS] = (0, 0)  # 装载结束
b2, n2, h2 = sim(6000, ev2, True)
ok2 = (n2 == 0) and (b2 == 0)
summary(b2, n2, 6000, h2, '场景 2：连续 8 次缩放重载（img_switch=0）→ 修复后画面永不黑')
PASS.append(('场景 2', ok2))
print('    %s 零转场、零黑屏（缩放时画面直接切换）' % ('✅' if ok2 else '❌'))
print()

# ---------------------------------------------------------------- 场景 3
# 旧行为对照：同样的缩放重载序列，若用 load_busy 上升沿触发（旧逻辑）
b3, n3, h3 = sim(6000, ev2, False)
summary(b3, n3, 6000, h3, '场景 3（对照）：旧逻辑（load_busy 上升沿触发）同样序列')
print('    → 旧逻辑会转场 %d 次、黑屏 %dms —— 这就是用户看到的"先黑屏"bug' % (n3, b3))
PASS.append(('场景 3 复现旧 bug', (n3 > 2) and (b3 > 300)))
print('    %s 旧逻辑确实大量转场+黑屏（bug 复现）' % ('✅' if (n3 > 2) and (b3 > 300) else '❌'))
print()

# ---------------------------------------------------------------- 场景 4
# 换图 + 缩放重载混合：换图转场做一半，缩放重载的 load_busy 脉动不应打断转场
ev4 = {1000: (1, 1),        # 换图开始 → 转场
       1450: (0, 0),        # 换图完成
       1700: (1, 0),        # 缩放重载开始（转场已在 F_IN，不应触发新转场）
       2050: (0, 0),        # 缩放重载完成
       2400: (1, 1),        # 又换图 → 新转场
       2750: (0, 0)}
b4, n4, h4 = sim(5000, ev4, True)
ok4 = (n4 == 2)
summary(b4, n4, 5000, h4, '场景 4：换图 → 缩放重载 → 换图（转场只跟换图走）')
PASS.append(('场景 4', ok4))
print('    %s 两次换图各转场 1 次、缩放重载不转场' % ('✅' if ok4 else '❌'))
print()

print('=' * 70)
print('  测试汇总')
print('=' * 70)
for name, ok in PASS:
    print('  %s %s' % ('✅' if ok else '❌', name))
print()
print('  结果: %d/%d 通过' % (sum(1 for _, o in PASS if o), len(PASS)))
print('=' * 70)
