# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : 仿真_端到端.py
 功能   : 逐拍仿真 "bmp_read 输出的像素流 -> img_scaler -> 输出像素"
          用来定位上板后"横的灰白条纹"花屏问题。
------------------------------------------------------------------------------
 特点（和 仿真_缩放.py 的区别）：
   * 严格按 img_scaler.v 的 RTL 逐拍翻译，一个时钟沿一拍，不跳步
   * ★ 建进了块 RAM 的 1 拍读延迟（O_data <= lbuf[addr]）
   * ★ 源像素按"每 GAP 拍来一个"的间隔到达（模拟 SPI 慢速装载）
   * 输出 640x480 个像素后，逐个和源图对比
==============================================================================
"""
SRC_W, SRC_H = 640, 480
ZOOM         = 100          # 缩放百分比（100 = 原图大小）
GAP          = 8            # 源像素到达间隔（拍）；真实约 106，这里加速但不影响正确性
EMIT_DIV     = 3            # ★ 与 RTL 的 EMIT_DIV 一致：每 4 拍吐一个像素
LBUF_N       = 2048

# 状态编码（与 RTL 一致）
S_IDLE,S_HD,S_WD,S_SKIP,S_FILL,S_NEXT,S_EMIT,S_DONE = range(8)

def src_pixel(x, y):
    """源图像素：R=列号低8位, G=行号低8位, B=0x80（便于反解坐标）"""
    return ((x & 0xFF) << 16) | ((y & 0xFF) << 8) | 0x80


class ImgScaler:
    def __init__(self):
        # ---- 预计算结果寄存器 ----
        self.w_dst=0; self.pad_left=0; self.img_end=0
        self.sx0=0; self.ha0=0; self.ca0=0
        self.h_dst=0; self.top_pad=0; self.top_has_pad=0
        self.img_bot=0; self.w_acc_init=0; self.black_row=0
        # ---- 运行时寄存器 ----
        self.st=S_IDLE
        self.sy=0; self.dy=0; self.w_acc=0; self.s_acc=0
        self.dx=0; self.h_acc=0; self.c_acc=0; self.sx=0
        self.emit_div=0
        self.tmp_num=0; self.tmp_quo=0
        self.rb=0; self.wp=0
        self.lbuf=[0]*LBUF_N
        # ---- 输出寄存器 ----
        self.O_wr=0; self.O_data=0; self.O_done=0
        # ---- 统计 ----
        self.out=[]            # 收集 (data) when O_wr
        self.occ_max=0
        self.st_hist={}

    def tick(self, i_wr, i_data, i_fs, I_W, I_H, Z):
        # ================= 组合逻辑（用当前寄存器值） =================
        zoom_use = 100 if Z < 50 else Z
        wr_ptr   = 0 if i_fs else self.wp
        rd_addr  = (self.rb + (self.sx & 0x7FF)) & 0x7FF
        occ      = (self.wp - self.rb) & 0x7FF
        row_ready= (I_W & 0x7FF) == 0 or occ >= (I_W & 0x7FF)
        ram_q    = self.lbuf[rd_addr]          # 异步读端口（下一拍出现在 O_data）
        if occ > self.occ_max: self.occ_max = occ

        # 横向 DDA 组合逻辑
        a  = self.h_acc + I_H
        cc = self.c_acc
        nn = self.sx
        for _ in range(8):
            if a >= cc:
                nn += 1
                cc += self.h_dst
        sx_next, c_acc_next = nn, cc

        # ================= 下一拍的值（RTL always 块开头先清零） =================
        n = dict(self.__dict__)      # 复制一份当 next（只改需要改的）
        n['O_wr'] = 0
        n['O_done'] = 0

        st = self.st
        if st == S_IDLE:
            n['sy']=0; n['dy']=0; n['w_acc']=0; n['s_acc']=0; n['rb']=0
            if i_fs:
                n['tmp_num'] = (zoom_use * 24) & 0xFFFFFFFF
                n['tmp_quo'] = 0
                n['st'] = S_HD
        elif st == S_HD:
            if self.tmp_num < 5:
                n['h_dst'] = self.tmp_quo & 0xFFFF
                if (self.tmp_quo & 0xFFFF) < SRC_H:
                    n['top_has_pad']=1
                    n['top_pad']=((SRC_H - (self.tmp_quo & 0xFFFF)) >> 1) & 0xFFFF
                    n['w_acc_init']=0
                else:
                    n['top_has_pad']=0
                    n['top_pad']=0
                    n['w_acc_init']=((((self.tmp_quo & 0xFFFF) - SRC_H) >> 1) * I_H) & 0xFFFFFFFF
                n['img_bot'] = ((SRC_H + (self.tmp_quo & 0xFFFF)) >> 1) & 0xFFFF
                n['tmp_num'] = (I_W * (self.tmp_quo & 0xFFFF)) & 0xFFFFFFFF
                n['tmp_quo'] = 0
                n['st'] = S_WD
            else:
                n['tmp_num'] = (self.tmp_num - 5) & 0xFFFFFFFF
                n['tmp_quo'] = (self.tmp_quo + 1) & 0xFFFFFFFF
        elif st == S_WD:
            if self.tmp_num < I_H:
                n['w_dst'] = self.tmp_quo & 0xFFFF
                if (self.tmp_quo & 0xFFFF) >= SRC_W:
                    n['pad_left']=0
                    n['img_end']=self.tmp_quo & 0xFFFF
                    n['tmp_num']=((((self.tmp_quo & 0xFFFF) - SRC_W) >> 1) * I_H) & 0xFFFFFFFF
                else:
                    n['pad_left']=((SRC_W - (self.tmp_quo & 0xFFFF)) >> 1) & 0xFFFF
                    n['img_end']=(((SRC_W - (self.tmp_quo & 0xFFFF)) >> 1) + (self.tmp_quo & 0xFFFF)) & 0xFFFF
                    n['tmp_num']=0
                n['tmp_quo']=0
                n['st']=S_SKIP
            else:
                n['tmp_num']=(self.tmp_num - I_H) & 0xFFFFFFFF
                n['tmp_quo']=(self.tmp_quo + 1) & 0xFFFFFFFF
        elif st == S_SKIP:
            if self.tmp_num < self.h_dst:
                n['sx0']=self.tmp_quo & 0xFFFF
                n['ha0']=self.tmp_num
                n['ca0']=self.h_dst
                n['w_acc']=self.w_acc_init
                n['st']=S_FILL
            else:
                n['tmp_num']=(self.tmp_num - self.h_dst) & 0xFFFFFFFF
                n['tmp_quo']=(self.tmp_quo + 1) & 0xFFFFFFFF
        elif st == S_FILL:
            if row_ready:
                n['s_acc']=(self.s_acc + self.h_dst) & 0xFFFFFFFF
                n['st']=S_NEXT
        elif st == S_NEXT:
            if self.dy >= SRC_H:
                n['O_done']=1
                n['st']=S_DONE
            elif self.top_has_pad and (self.dy < self.top_pad):
                n['black_row']=1; n['dx']=0; n['st']=S_EMIT
            elif self.dy >= self.img_bot:
                n['black_row']=1; n['dx']=0; n['st']=S_EMIT
            elif self.sy >= I_H:
                n['black_row']=1; n['dx']=0; n['st']=S_EMIT
            elif self.w_acc < self.s_acc:
                n['black_row']=0; n['dx']=0
                n['h_acc']=self.ha0; n['c_acc']=self.ca0; n['sx']=self.sx0
                n['st']=S_EMIT
            else:
                n['sy']=self.sy+1
                n['rb']=(self.rb + (I_W & 0x7FF)) & 0x7FF
                n['st']=S_FILL
        elif st == S_EMIT:
            if self.dx >= SRC_W:
                n['dy']=self.dy+1
                if not self.black_row:
                    n['w_acc']=(self.w_acc + I_H) & 0xFFFFFFFF
                n['st']=S_NEXT
            elif self.emit_div != 0:
                n['emit_div'] = self.emit_div - 1      # ★ 分频等待拍：不吐像素
            else:
                n['emit_div'] = EMIT_DIV               # ★ 吐完这个像素后等 EMIT_DIV 拍
                n['O_wr']=1
                if self.black_row:
                    n['O_data']=0
                else:
                    if (self.dx < self.pad_left) or (self.dx >= self.img_end):
                        n['O_data']=0
                    else:
                        n['O_data']=ram_q      # ★ 块 RAM 读出（1 拍前给出的地址）
                    if (self.dx >= self.pad_left) and (self.dx < self.img_end):
                        n['h_acc']=(self.h_acc + I_H) & 0xFFFFFFFF
                        n['sx']=sx_next
                        n['c_acc']=c_acc_next
                n['dx']=self.dx+1
        elif st == S_DONE:
            n['sy']=0; n['dy']=0; n['w_acc']=0; n['s_acc']=0; n['rb']=0
            if i_fs:
                n['tmp_num']=(zoom_use*24) & 0xFFFFFFFF
                n['tmp_quo']=0
                n['st']=S_HD

        # ---- 写指针（独立的 always 块）----
        if i_fs:      n['wp']=1
        elif i_wr:    n['wp']=(self.wp+1) & 0x7FF

        # ---- 输出收集 ----
        if self.O_wr:
            self.out.append(self.O_data)

        # ---- 提交：先提交状态机寄存器，再写行缓存（读旧写新，与 RTL 一致）----
        keep_lbuf = self.lbuf
        self.__dict__.update(n)
        self.lbuf = keep_lbuf
        if i_wr:
            self.lbuf[wr_ptr] = i_data

        self.st_hist[st]=self.st_hist.get(st,0)+1


def run(n_frames=3, verbose_frame=0):
    """连续跑 n_frames 帧：真实场景就是"装载第1张 -> 显示 -> 装载第2张 -> ..."
       帧与帧之间模拟一段空闲（SPI 在扫描/等待，没有像素来）"""
    sc = ImgScaler()
    total_src = SRC_W * SRC_H
    tick = 0
    print('=' * 66)
    print('  端到端逐拍仿真：连续 %d 帧（%dx%d, zoom=%d%%）' % (n_frames, SRC_W, SRC_H, ZOOM))
    print('=' * 66)

    for f in range(n_frames):
        sent = 0
        fs_pending = True
        idle = 0
        start_out = len(sc.out)
        while True:
            i_wr = 0; i_data = 0; i_fs = 0
            if sent < total_src and (tick % GAP) == 0:
                x = sent % SRC_W; y = sent // SRC_W
                i_wr = 1; i_data = src_pixel(x, y)
                if fs_pending:
                    i_fs = 1; fs_pending = False
                sent += 1
            sc.tick(i_wr, i_data, i_fs, SRC_W, SRC_H, ZOOM)
            tick += 1
            if len(sc.out) - start_out >= total_src:
                break
            if sent >= total_src:
                idle += 1
                # 数据送完后，img_scaler 还要把最后几行吐出来（每行 640 拍），
                # 所以这里要给足余量；超过 3000 拍还没完才算真的卡住
                if idle > 3000:
                    print('  !! 第 %d 帧卡住：只输出 %d / %d 个像素'
                          % (f + 1, len(sc.out) - start_out, total_src))
                    return
        # ---- 帧间空闲：模拟 SPI 去扫下一个文件（没有像素数据）----
        for _ in range(50):
            sc.tick(0, 0, 0, SRC_W, SRC_H, ZOOM)
            tick += 1
        # ---- 本帧比对 ----
        seg = sc.out[start_out:start_out + total_src]
        bad = 0; first = None
        for i, v in enumerate(seg):
            exp = src_pixel(i % SRC_W, i // SRC_W)
            if v != exp:
                bad += 1
                if first is None:
                    first = (i, i % SRC_W, i // SRC_W, v, exp)
        if bad == 0:
            print('  第 %d 帧：输出 %d 个像素，逐像素全对 ✅' % (f + 1, len(seg)))
        else:
            print('  第 %d 帧：错 %d / %d 个像素 ❌' % (f + 1, bad, total_src))
            if first:
                i, x, y, v, e = first
                print('      第一个错在 第%d个像素 (x=%d,y=%d)：实际=0x%06X 期望=0x%06X'
                      % (i, x, y, v, e))
                print('      实际像素自带的坐标字段 = (x=%d, y=%d)  ← 数据其实来自这里'
                      % ((v >> 16) & 0xFF, (v >> 8) & 0xFF))
    print()
    print('  行缓存最大占用 = %d / %d' % (sc.occ_max, LBUF_N))
    print('  总拍数 = %d' % tick)


if __name__ == '__main__':
    run()
