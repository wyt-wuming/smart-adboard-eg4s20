# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 仿真_bmp读取.py
 功能   : 用**真实 BMP 文件**逐字节驱动 bmp_read 的 LOAD_DATA 逻辑，
          检查吐出的像素流对不对（像素数、字节顺序、O_frame_start 时机）。
          同时对比"修复行填充前 / 修复后"两种行为。
------------------------------------------------------------------------------
 背景：
   上板后画面是"横的灰白条纹"。img_scaler 已用端到端仿真证明正确，
   问题落在"喂给它的像素流"上 —— bmp_read 原先是按"每 3 字节一个像素"
   连续读的，**不跳过 BMP 的行填充**，宽度不是 4 的倍数时每行都会错位。
   修复：行尾填充字节数恰好 = W mod 4（3W ≡ -W (mod 4)），取低 2 位即可，
        每输出完一行的最后一个像素就跳过这么多字节。
==============================================================================
"""
import os, struct, sys

BS = chr(92)


def read_bmp(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:2] == b'BM', '不是 BMP'
    return dict(
        data=data,
        file_len     = struct.unpack('<I', data[2:6])[0],
        pixel_offset = struct.unpack('<I', data[10:14])[0],
        width        = struct.unpack('<i', data[18:22])[0],
        height       = struct.unpack('<i', data[22:26])[0],
        bpp          = struct.unpack('<H', data[28:30])[0],
        compression  = struct.unpack('<I', data[30:34])[0],
    )


def simulate_bmp_read(bmp, fix_pad):
    """逐拍翻译 bmp_read.v 的 LOAD_DATA 逻辑。fix_pad=False 模拟修复前的行为。"""
    data = bmp['data']
    file_len, off = bmp['file_len'], bmp['pixel_offset']
    W = abs(bmp['width'])
    cnt = 0; idx = 0; wr_en = 0; bmp_data = 0
    col_pix = 0; pad_cnt = 0
    out = []; fs_ticks = []; fs_old_hits = 0
    for t in range(len(data) + 2):
        byte = data[t] if t < len(data) else None
        # ---- 组合逻辑 ----
        bdv    = (byte is not None) and (cnt >= off) and (cnt < file_len)
        fs     = 1 if (wr_en and cnt == off + 3) else 0      # 修复后的 O_frame_start
        fs_old = 1 if (wr_en and cnt == off)     else 0      # 修复前的判断（对照）
        if fs: fs_ticks.append(t)
        if fs_old: fs_old_hits += 1
        if wr_en: out.append(bmp_data)
        # ---- 时序更新 ----
        if fix_pad and pad_cnt != 0:
            nxt_pad, nxt_idx, nxt_wr = pad_cnt - 1, 0, 0     # 跳过填充字节
        elif bdv:
            if   idx == 0: bmp_data = (bmp_data & 0xFFFF00) | byte
            elif idx == 1: bmp_data = (bmp_data & 0xFF00FF) | (byte << 8)
            else:          bmp_data = (bmp_data & 0x00FFFF) | (byte << 16)
            if idx == 2:
                nxt_wr, nxt_idx = 1, 0
                if fix_pad:
                    if col_pix + 1 >= W:
                        col_pix = 0; nxt_pad = W % 4         # ★ 行尾填充 = W mod 4
                    else:
                        col_pix += 1; nxt_pad = 0
                else:
                    nxt_pad = 0
            else:
                nxt_wr, nxt_idx, nxt_pad = 0, idx + 1, 0
        else:
            nxt_wr, nxt_idx, nxt_pad = 0, idx, pad_cnt
        cnt += 1
        wr_en, idx, pad_cnt = nxt_wr, nxt_idx, nxt_pad
    return out, fs_ticks, fs_old_hits


def compare(bmp, out):
    """按文件字节顺序逐像素比对（bmp_read 就是按文件顺序吐的）"""
    data = bmp['data']; off = bmp['pixel_offset']
    W = abs(bmp['width'])
    row_raw  = W * 3
    rowbytes = ((row_raw + 3) // 4) * 4
    bad = 0; first = None
    for i in range(len(out)):
        r, c = divmod(i, W)
        base = off + r * rowbytes + c * 3
        if base + 2 >= len(data): break
        exp = (data[base+2] << 16) | (data[base+1] << 8) | data[base]
        if out[i] != exp:
            bad += 1
            if first is None: first = (i, r, c, out[i], exp)
    return bad, first


def check(path):
    b = read_bmp(path)
    W, H = abs(b['width']), abs(b['height'])
    row_raw  = W * 3
    pad      = ((row_raw + 3) // 4) * 4 - row_raw
    print('=' * 72)
    print('文件：%s   %dx%d  %dbit  压缩=%d  头长=%d'
          % (os.path.basename(path), W, H, b['bpp'], b['compression'], b['pixel_offset']))
    print('  每行 %d 字节 → 对齐到 %d，行填充 = %d 字节'
          % (row_raw, ((row_raw + 3) // 4) * 4, pad))

    for label, fix in (('修复前', False), ('修复后', True)):
        out, fst, fold = simulate_bmp_read(b, fix)
        bad, first = compare(b, out)
        n_expect = W * H
        ok_num = (len(out) == n_expect)
        print('  【%s】吐出像素 %6d / 应为 %6d %s  比对错 %6d %s'
              % (label, len(out), n_expect,
                 '✅' if ok_num else '❌', bad, '✅' if bad == 0 else '❌'))
        if first and label == '修复前' and pad:
            i, r, c, got, exp = first
            print('         （修复前第一个错在文件第 %d 行第 %d 列）' % (r, c))
    print('  O_frame_start：修复判断后触发 %d 次，原判断 %d 次%s'
          % (len(fst), fold, '  ← 原判断永远不来' if fold == 0 else ''))
    print()


def make_test_bmp(path, w, h):
    from PIL import Image
    img = Image.new('RGB', (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (x & 0xFF, y & 0xFF, 0x80)
    img.save(path, 'BMP')


if __name__ == '__main__':
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    tests = []
    for n in ('doc/convert/1.bmp', 'doc/convert/output_bmp/1.bmp'):
        p = os.path.join(root, n.replace('/', BS))
        if os.path.exists(p):
            tests.append(p); break
    print('生成对比测试图...')
    tmp1 = os.path.join(root, 'tools', '_t640.bmp')
    tmp2 = os.path.join(root, 'tools', '_t641.bmp')
    tmp3 = os.path.join(root, 'tools', '_t642.bmp')
    make_test_bmp(tmp1, 640, 480)     # 4 的倍数
    make_test_bmp(tmp2, 641, 480)     # pad = 1
    make_test_bmp(tmp3, 642, 480)     # pad = 2
    tests += [tmp1, tmp2, tmp3]
    for p in tests:
        check(p)
    print('=' * 72)
    print('结论：')
    print('  * 宽度是 4 的倍数 → 没有填充，修复前后都对')
    print('  * 宽度不是 4 的倍数 → 修复前逐行错位（花屏），修复后全对')
    for p in (tmp1, tmp2, tmp3):
        try: os.remove(p)
        except Exception: pass
