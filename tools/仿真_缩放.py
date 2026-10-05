# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 仿真_缩放.py
 功能   : 把 SD/img_scaler.v 逐拍翻译成 Python 做逻辑仿真（含"输入时序"）
------------------------------------------------------------------------------
 为什么要做这个？
   缩放算法（DDA）本身在纸上算过是对的，但**接上真实数据流之后**才是真正
   要验证的东西：bmp_read 是"读到一个像素就往外吐一个"，没有 ready 可以暂停，
   只要状态机没空接，那个像素就永远丢了 → 行边界错位 → 画面变斜。

 仿真尺度说明（重要）：
   真机一整帧：输出 640x480 要 31 万拍，源像素以约 106 拍/像素 到达
   （SD 走 SPI 25MHz：35 拍/字节 x 3 字节/像素）。
   Python 跑 3000 万拍太慢，所以这里把**画面和输入速率同时缩小 4 倍**：
      输出 160x120、输入约 26.5 拍/像素、行缓存 512 深
   关键是比例不变 —— "每输出一行会漏掉多少源像素"：
      真机 640/106 = 6.0 个/行      仿真 160/26.5 = 6.0 个/行
   所以这个仿真能忠实复现"漏像素"故障，也能验证修好了没有。

 验证办法：
   把源图像做成"坐标图"：每个像素的值 = 它自己的坐标 (y<<12 | x)。
   输出画面里每个像素都能反解出"你是源图的哪个点"，
   于是"一行里混进两行源数据""逐行漂移"这类故障一眼可见。

 对照实验：
   drop_old=True  = 旧版行为（只在 S_FILL 里写 lbuf[col]，其余时间到的像素丢掉）
   drop_old=False = 新版行为（写侧无条件收，行缓存当"循环原始缓冲"用）

 与 img_scaler.v 的对应（改 RTL 后请同步改这里）：
   八个状态 S_IDLE/S_HD/S_WD/S_SKIP/S_FILL/S_NEXT/S_EMIT/S_DONE、
   纵向 DDA(w_acc/s_acc)、横向 DDA(h_acc/c_acc/sx_next)、
   写侧 wp / 行基址 rb / row_ready(occ >= I_w)、以及 S_DONE → S_HD 多帧路径。
==============================================================================
"""

# ---- 真机参数 ----
DST_W, DST_H = 640, 480
CYC_PER_PX_REAL = 106.0      # 实测：SPI 25MHz、35 拍/字节 → 约 106 拍/像素
LBUF_REAL = 2048
SCALE = 0.25                 # 仿真缩小系数（画面与速率同步缩小，比例不变）

S_IDLE, S_HD, S_WD, S_SKIP, S_FILL, S_NEXT, S_EMIT, S_DONE = range(8)
STATE_NAME = {S_IDLE: 'IDLE', S_HD: 'HD', S_WD: 'WD', S_SKIP: 'SKIP',
              S_FILL: 'FILL', S_NEXT: 'NEXT', S_EMIT: 'EMIT', S_DONE: 'DONE'}


def simulate(src_w, src_h, zoom, frames=1, drop_old=False, done_old=False):
    """逐拍仿真。返回 dict(out=每帧的行列表, dropped, max_occ, stats)
       done_old=True 时复现旧版 S_DONE 分支（跳过 S_HD、用写死的 480 算宽度）"""
    dst_w = int(round(DST_W * SCALE))          # 160
    dst_h = int(round(DST_H * SCALE))          # 120
    lbuf_n = int(round(LBUF_REAL * SCALE))     # 512
    cyc_per_px = CYC_PER_PX_REAL * SCALE       # 26.5

    total_px = src_w * src_h
    # 源图：坐标图案（像素值 = 自己的坐标）
    src = [((y << 12) | (x & 0xFFF)) for y in range(src_h) for x in range(src_w)]

    lbuf = [0] * lbuf_n
    pend_wr = None            # 上一拍"发出"的写，本拍生效（模拟块 RAM 时序）
    frames_out, dropped = [], 0
    max_occ, occ_over, state_hist = 0, 0, {}
    # ---- 状态机寄存器（跨帧保持，初值 = 上电复位）----
    state = S_IDLE
    wp = rb = 0
    sy = dy = 0
    w_acc = s_acc = 0
    dx = 0
    h_acc = c_acc = sx = 0
    w_dst = pad_left = img_end = sx0 = 0
    ha0 = ca0 = 0
    h_dst = top_pad = img_bot = 0
    top_has_pad = 0
    w_acc_init = 0
    black_row = 0
    tmp_num = tmp_quo = 0

    for frame in range(frames):
        # 允许 zoom 传列表：一帧换一个值（用来验证 S_DONE → 下一帧 的路径）
        z = zoom[frame] if isinstance(zoom, (list, tuple)) else zoom
        # ★ 注意：状态机和各寄存器**跨帧保持**（真机上就是一直跑着的），
        #   每帧只重置"源数据流"和输出收集 —— 这样 S_DONE 那条路径才会被走到。
        k = 0
        t_next = 0.0
        col_old = 0
        frame_start = True        # 第一个像素到达当拍 = I_frame_start
        out, cur_row = [], []
        t = 0.0
        guard = 0

        # ★ 跑到"整帧输出完、状态机回到 S_DONE"为止 —— 真机上两次装载之间
        #   隔着约 350ms（整帧早就输出完了，状态机一直停在 S_DONE 等下一次
        #   I_frame_start），所以必须让状态机先收尾，再开始下一帧的数据。
        while (len(out) < dst_h or state != S_DONE) and guard < 3_000_000:
            guard += 1
            # 源像素已经全部送完、状态机还在等数据 → 卡死（旧版就会这样）
            if k >= total_px and len(out) < dst_h and state in (S_FILL, S_IDLE):
                break
            # ---------- 1) 上一拍发出的写在本拍生效 ----------
            if pend_wr is not None:
                lbuf[pend_wr[0]] = pend_wr[1]
                pend_wr = None
            # ---------- 2) 输入侧：本拍到像素了吗 ----------
            wr, data = False, 0
            if k < total_px and t >= t_next - 1e-9:
                wr, data = True, src[k]
                k += 1
                t_next += cyc_per_px

            # ---------- 3) 写侧 ----------
            if wr and not drop_old:
                # 新版：无条件收进"循环原始缓冲"，与状态机无关
                #   ★ 换图第一拍写 0 号位置、并把写指针复位成 1（与 RTL 一致）
                pend_wr = (0 if frame_start else wp, data)
                wp = 1 if frame_start else (wp + 1) % lbuf_n
            frame_start = False

            # ---------- 4) 状态机（照抄 RTL；非阻塞赋值用 st 表示次态）----------
            st = state
            if st == S_IDLE:
                sy = dy = 0
                w_acc = s_acc = 0
                rb = 0
                if wr:
                    tmp_num, tmp_quo = z * dst_h, 0        # = zoom x 480/100 的等比形式
                    st = S_HD
            elif st == S_HD:
                if tmp_num < 100:
                    h_dst = tmp_quo
                    if tmp_quo < dst_h:
                        top_has_pad = 1
                        top_pad = (dst_h - tmp_quo) >> 1
                        w_acc_init = 0
                    else:
                        top_has_pad = 0
                        top_pad = 0
                        w_acc_init = ((tmp_quo - dst_h) >> 1) * src_h
                    img_bot = (dst_h + tmp_quo) >> 1
                    tmp_num, tmp_quo = src_w * tmp_quo, 0
                    st = S_WD
                else:
                    tmp_num -= 100
                    tmp_quo += 1
            elif st == S_WD:
                if tmp_num < src_h:
                    w_dst = tmp_quo
                    if tmp_quo >= dst_w:
                        pad_left = 0
                        img_end = tmp_quo
                        tmp_num = ((tmp_quo - dst_w) >> 1) * src_h
                    else:
                        pad_left = (dst_w - tmp_quo) >> 1
                        img_end = pad_left + tmp_quo
                        tmp_num = 0
                    tmp_quo = 0
                    st = S_SKIP
                else:
                    tmp_num -= src_h
                    tmp_quo += 1
            elif st == S_SKIP:
                if tmp_num < h_dst:
                    sx0, ha0, ca0 = tmp_quo, tmp_num, h_dst
                    w_acc = w_acc_init
                    st = S_FILL
                else:
                    tmp_num -= h_dst
                    tmp_quo += 1
            elif st == S_FILL:
                if drop_old:
                    # 旧版：靠 I_wr 收满一整行才算好（其余时间到的像素丢）
                    if wr:
                        pend_wr = (col_old, data)
                        if col_old + 1 >= src_w:
                            col_old = 0
                            s_acc += h_dst
                            st = S_NEXT
                        else:
                            col_old += 1
                else:
                    # 新版：数据早在缓冲里，只等"整行到齐"
                    if ((wp - rb) % lbuf_n) >= src_w:
                        s_acc += h_dst
                        st = S_NEXT
            elif st == S_NEXT:
                if dy >= dst_h:
                    st = S_DONE
                elif top_has_pad and dy < top_pad:
                    black_row, dx, st = 1, 0, S_EMIT
                elif dy >= img_bot:
                    black_row, dx, st = 1, 0, S_EMIT
                elif sy >= src_h:
                    black_row, dx, st = 1, 0, S_EMIT
                elif w_acc < s_acc:
                    black_row, dx = 0, 0
                    h_acc, c_acc, sx = ha0, ca0, sx0
                    st = S_EMIT
                else:
                    sy += 1
                    rb = (rb + src_w) % lbuf_n
                    col_old = 0
                    st = S_FILL
            elif st == S_EMIT:
                if dx >= dst_w:
                    dy += 1
                    if not black_row:
                        w_acc += src_h
                    st = S_NEXT
                elif black_row:
                    cur_row.append(0)
                    dx += 1
                else:
                    if dx < pad_left or dx >= img_end:
                        cur_row.append(0)
                    else:
                        pos = sx if drop_old else (rb + sx) % lbuf_n
                        cur_row.append(lbuf[pos])
                    if pad_left <= dx < img_end:
                        # 组合逻辑：用"本拍还没更新的 h_acc"算下一列
                        a, cc, nn = h_acc + src_h, c_acc, sx
                        for _ in range(8):
                            if a >= cc:
                                nn += 1
                                cc += h_dst
                        h_acc += src_h
                        sx, c_acc = nn, cc
                    dx += 1
            elif st == S_DONE:
                if wr:
                    sy = dy = 0
                    w_acc = s_acc = 0
                    rb = 0
                    if done_old:
                        # 旧版：跳过 S_HD、宽度按写死的 480 算 → h_dst 是上一帧的残留值
                        tmp_num, tmp_quo = src_w * dst_h, 0
                        st = S_WD
                    else:
                        tmp_num, tmp_quo = z * dst_h, 0    # ★ 修正后同样走 S_HD
                        st = S_HD
            if wr and drop_old and state != S_FILL:
                dropped += 1
            state_hist[STATE_NAME[st]] = state_hist.get(STATE_NAME[st], 0) + 1
            state = st
            t += 1.0
            if len(cur_row) >= dst_w:
                out.append(cur_row[:dst_w])
                cur_row = []
            if not drop_old:
                occ = (wp - rb) % lbuf_n
                if occ > max_occ:
                    max_occ = occ
                if occ >= lbuf_n:
                    occ_over += 1
        frames_out.append(out)
    zs = list(zoom) if isinstance(zoom, (list, tuple)) else [zoom] * frames
    return dict(out=frames_out, dropped=dropped, max_occ=max_occ,
                occ_over=occ_over, lbuf_n=lbuf_n, zooms=zs,
                dst_w=dst_w, dst_h=dst_h)


def geometry(src_w, src_h, zoom, dst_w, dst_h):
    """按"设计意图"算出该有的几何（独立于上面的状态机实现）"""
    h_dst = (zoom * dst_h) // 100
    top_has_pad = h_dst < dst_h
    top_pad = (dst_h - h_dst) >> 1 if top_has_pad else 0
    img_bot = (dst_h + h_dst) >> 1
    w_dst = (src_w * h_dst) // src_h
    if w_dst >= dst_w:
        pad_left, img_end = 0, w_dst
    else:
        pad_left = (dst_w - w_dst) >> 1
        img_end = pad_left + w_dst
    return dict(h_dst=h_dst, top_has_pad=top_has_pad, top_pad=top_pad,
                img_bot=img_bot, w_dst=w_dst, pad_left=pad_left, img_end=img_end)


def check_frame(out, src_w, src_h, zoom, dst_w, dst_h):
    """返回问题列表：黑边/撕裂/漂移"""
    g = geometry(src_w, src_h, zoom, dst_w, dst_h)
    pb = []
    if len(out) < dst_h:
        pb.append('整帧没输出完：只有 %d / %d 行（源像素被丢光了）'
                  % (len(out), dst_h))
    for dy in range(min(len(out), dst_h)):
        if (g['top_has_pad'] and dy < g['top_pad']) or dy >= g['img_bot']:
            if any(p != 0 for p in out[dy]):
                pb.append('第 %d 行应是黑边却有内容' % dy)
    y0 = g['top_pad'] if g['top_has_pad'] else 0
    # 纵向上"理想映射"：图像虚拟顶边 y0_signed（放大时为负 = 上方被裁）
    y0_signed = (dst_h - g['h_dst']) >> 1
    seq = []
    for dy in range(y0, min(g['img_bot'], dst_h, len(out))):
        seg = [p for p in out[dy][g['pad_left']:min(g['img_end'], dst_w)] if p != 0]
        ys = sorted(set(p >> 12 for p in seg))
        if len(ys) > 1:
            pb.append('第 %d 行混进了 %d 个源行 %s（撕裂/错位）' % (dy, len(ys), ys[:4]))
        if seg:
            seq.append((seg[0] >> 12, dy))
            ideal = (dy - y0_signed) * src_h // g['h_dst']
            if abs(seg[0] >> 12) - ideal > 2 or ideal - (seg[-1] >> 12) > 2:
                pb.append('第 %d 行纵向映射偏了：源行 %d~%d，理想 %d'
                          % (dy, seg[0] >> 12, seg[-1] >> 12, ideal))
    for i in range(1, len(seq)):
        if seq[i][0] < seq[i - 1][0]:
            pb.append('源行号回退：dy=%d 用源行 %d，上一行 %d'
                      % (seq[i][1], seq[i][0], seq[i - 1][0]))
            break
    # 横向：图像区第一个/最后一个像素对应的源列
    x0_signed = (dst_w - g['w_dst']) >> 1
    if g['h_dst'] > 0:
        dy_mid = (y0 + min(g['img_bot'], dst_h, len(out))) // 2
        if dy_mid < len(out):
            seg = [p for p in out[dy_mid][g['pad_left']:min(g['img_end'], dst_w)] if p != 0]
            if seg:
                xs = [p & 0xFFF for p in seg]
                ideal_l = (g['pad_left'] - x0_signed) * src_w // g['w_dst']
                ideal_r = (min(g['img_end'], dst_w) - 1 - x0_signed) * src_w // g['w_dst']
                if abs(xs[0] - ideal_l) > 2 or abs(xs[-1] - ideal_r) > 2:
                    pb.append('第 %d 行横向映射偏了：源列 %d~%d，理想 %d~%d'
                              % (dy_mid, xs[0], xs[-1], ideal_l, ideal_r))
    return pb, g


PASS = []


def run(tag, src_w, src_h, zoom, frames=1, drop_old=False, done_old=False,
        expect_ok=True):
    r = simulate(src_w, src_h, zoom, frames, drop_old, done_old)
    print('-' * 72)
    print('%s' % tag)
    zs_txt = '→'.join('%d%%' % v for v in r['zooms'])
    print('   源图 %dx%d  zoom=%s  →  输出 %dx%d（仿真尺度）'
          % (src_w, src_h, zs_txt, r['dst_w'], r['dst_h']))
    if drop_old:
        print('   旧版行为：丢掉的源像素 = %d 个/帧' % (r['dropped'] // max(1, frames)))
    else:
        print('   新版行为：丢弃 0 个；行缓存最大占用 = %d / %d'
              % (r['max_occ'], r['lbuf_n']))
    all_ok = True
    for i, out in enumerate(r['out']):
        zf = r['zooms'][i] if i < len(r['zooms']) else zoom
        pb, g = check_frame(out, src_w, src_h, zf, r['dst_w'], r['dst_h'])
        if pb:
            all_ok = False
            print('   ❌ 第 %d 帧：%s' % (i + 1, pb[0]))
            if len(pb) > 1:
                print('            （还有 %d 处同类问题）' % (len(pb) - 1))
        else:
            print('   ✅ 第 %d 帧几何正确（黑边/%s）'
                  % (i + 1, '缩放 %.0f%%' % (100.0 * g['h_dst'] / r['dst_h'])))
    PASS.append((tag, all_ok == expect_ok))
    return r, all_ok


print('=' * 72)
print('  img_scaler.v 逐拍仿真（画面与输入速率同步缩小 4 倍，比例不变）')
print('=' * 72)

# =============================== 测试 1 ===============================
print()
print('【测试 1】旧版 vs 新版：源图 640x480（仿真 160x120），zoom=100%')
r_old, _ = run('  ① 旧版（写侧只在 S_FILL 收像素）', 160, 120, 100,
               frames=1, drop_old=True, expect_ok=False)
r_new, ok1 = run('  ② 新版（写侧无条件收）', 160, 120, 100,
                 frames=1, drop_old=False, expect_ok=True)

# 最强检查：100% 且源图与输出同尺寸时，输出必须逐像素等于源图
src = [((y << 12) | x) for y in range(120) for x in range(160)]
if ok1:
    bad = 0
    for y in range(120):
        for x in range(160):
            if r_new['out'][0][y][x] != src[y * 160 + x]:
                bad += 1
    print('   逐像素比对：%s（不同 %d 个）'
          % ('✅ 完全一致' if bad == 0 else '❌ 不一致', bad))
    PASS.append(('zoom=100%% 且同尺寸时逐像素等于源图', bad == 0))
    # 旧版同样比一下，看看错成什么样
    bad_old, sample, rows_old = 0, None, len(r_old['out'])
    for y in range(min(rows_old, 120)):
        for x in range(160):
            if r_old['out'][0][y][x] != src[y * 160 + x]:
                bad_old += 1
                if sample is None and y > 10:
                    sample = (y, x, r_old['out'][0][y][x] >> 12, y)
    print('   旧版同一帧：只输出 %d/120 行，其中已输出的 %d 个像素与源图不符'
          % (rows_old, bad_old))
    if sample:
        print('      例如第 %d 行第 %d 列显示的是源图第 %d 行的内容（应该显示第 %d 行）'
              % (sample[0], sample[1], sample[2], sample[3]))
    print('      → 旧版连"整帧输出完"都做不到（O_done 永远不来，画面根本切不过去）')

# =============================== 测试 2 ===============================
print()
print('【测试 2】缩小 50%：上下各补黑边（这是旧版丢像素最严重的场景）')
run('  ① 旧版', 160, 120, 50, frames=1, drop_old=True, expect_ok=False)
run('  ② 新版', 160, 120, 50, frames=1, drop_old=False, expect_ok=True)

# =============================== 测试 3 ===============================
print()
print('【测试 3】放大 200%：超出部分裁掉')
run('  新版', 160, 120, 200, frames=1, drop_old=False, expect_ok=True)

# =============================== 测试 4 ===============================
print()
print('【测试 4】不同长宽比：800x600 正好铺满（仿真 200x150）')
run('  新版', 200, 150, 100, frames=1, drop_old=False, expect_ok=True)

# =============================== 测试 5 ===============================
print()
print('【测试 5】★ 连续 3 帧、每帧换一个缩放值 —— 验证 S_DONE 之后的第 2、3 帧')
print('   （旧版 S_DONE → S_WD 用写死的 480 算宽度，第 2 帧起就会变形）')
print()
run('  ▲ 旧版（对照）：一次连续跑 3 帧，缩放 100% → 50% → 200%',
    160, 120, [100, 50, 200], frames=3, drop_old=False, done_old=True, expect_ok=False)
print()
run('  ★ 新版（修正后）：同样连续跑 3 帧，缩放 100% → 50% → 200%',
    160, 120, [100, 50, 200], frames=3, drop_old=False, expect_ok=True)

# =============================== 测试 6 ===============================
print()
print('【测试 6】极端：很窄的源图 100x300（仿真 25x75）缩小 50%')
run('  新版', 25, 75, 50, frames=1, drop_old=False, expect_ok=True)

# =============================== 汇总 ===============================
print()
print('=' * 72)
print('  测试汇总')
print('=' * 72)
for name, ok in PASS:
    print('  %s %s' % ('✅' if ok else '❌', name))
n_ok = sum(1 for _, o in PASS if o)
print()
print('  结果: %d/%d 通过' % (n_ok, len(PASS)))
print('=' * 72)
