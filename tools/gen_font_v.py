# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : gen_font_v.py
 功能   : 生成 OSD 用的 16x16 点阵字库，并直接输出成 Verilog 文件
------------------------------------------------------------------------------
 为什么输出成 .v 而不是 .mif？
   用 .mif + $readmemh 时，综合工具"从哪里找文件"很不确定（跟工作目录有关），
   经常报 "cannot open file"。直接把字模写成 Verilog 常量数组最稳妥，
   不依赖任何外部文件路径。

 用法   : python gen_font_v.py
 依赖   : pillow
 输出   : src/user_source/hdl_source/video/font_rom.v
          preview_font.png （字模预览图，用来肉眼检查字形）

 字库内容（21 个字符，每个 16 行，每行 16 bit，MSB 在左）：
   索引 0~9  : 数字 '0'~'9'
   索引 10~16: 亮 度 对 比 周 期 秒
   索引 17   : 空白（不点亮任何像素）
   索引 18~20: 缩 放 %      ★【新增】给"画面缩放"调节项用
 ★ 新字符只能往后面加！一旦插到中间，所有索引都会移位，
   osd_adjust.v 里的 5'd10 / 5'd18 这些常量就全错了。
==============================================================================
"""
import os
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = r"C:\Windows\Fonts\simhei.ttf"   # 黑体，点阵显示清楚
FONT_SIZE = 16
OFF_X, OFF_Y = 0, 0
CW, CH = 16, 16

CHARS = (list("0123456789") + ['亮', '度', '对', '比', '周', '期', '秒'] + [' ']
         + ['缩', '放', '%'])

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_V   = os.path.join(BASE, "..", "src", "user_source", "hdl_source", "video", "font_rom.v")
OUT_PNG = os.path.join(BASE, "preview_font.png")


def render(ch, font):
    """把一个字符渲染成 16x16 点阵，返回 16 个 16bit 整数"""
    img = Image.new("1", (CW, CH), 0)
    ImageDraw.Draw(img).text((OFF_X, OFF_Y), ch, font=font, fill=1)
    px = img.load()
    rows = []
    for y in range(CH):
        v = 0
        for x in range(CW):
            if px[x, y]:
                v |= (0x8000 >> x)   # MSB 在左
        rows.append(v)
    return rows


def main():
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    all_rows = []
    char_map = []
    for ch in CHARS:
        rows = render(ch, font)
        char_map.append((ch, rows))
        all_rows.extend(rows)

    total = len(all_rows)
    print("字符数 = %d, 总行数 = %d" % (len(CHARS), total))

    # ---------------- 输出 Verilog ----------------
    os.makedirs(os.path.dirname(OUT_V), exist_ok=True)
    with open(OUT_V, "w", encoding="utf-8") as f:
        f.write("//==============================================================================\n")
        f.write("//  文件名  : font_rom.v   （由 tools/gen_font_v.py 自动生成，请勿手改）\n")
        f.write("//  功能    : 16x16 点阵字库，供 OSD 调节界面显示绿色汉字与数字\n")
        f.write("//------------------------------------------------------------------------------\n")
        f.write("//  字库内容（%d 个字符，每字符 16 行，每行 16bit，MSB 在左）：\n" % len(CHARS))
        f.write("//     索引 0~9  : 数字 '0'~'9'\n")
        f.write("//     索引 10~16: 亮 度 对 比 周 期 秒\n")
        f.write("//     索引 17   : 空白\n")
        f.write("//     索引 18~20: 缩 放 %\n")
        f.write("//  ★ 地址 = 字符索引 * 16 + 行号(0~15)，即 {字符索引[4:0], 行号[3:0]}\n")
        f.write("//    最大地址 = %d*16+15 = %d（ROM 深 512，放得下）\n" % (len(CHARS)-1, len(CHARS)*16-1))
        f.write("//==============================================================================\n\n")
        f.write("module font_rom (\n")
        f.write("    input  wire        clk,        // 视频时钟\n")
        f.write("    input  wire [8:0]  addr,       // {字符索引[4:0], 行号[3:0]}，最大 17*16+15 = 287\n")
        f.write("    output reg  [15:0] data        // 该行 16 个像素，bit15 在最左\n")
        f.write(");\n\n")
        f.write("    // 字库存储（512 深，只用到前 %d 个）\n" % total)
        f.write("    reg [15:0] mem [0:511];\n\n")
        f.write("    initial begin\n")
        # 先把整块清零，未用到的地址读出 0（不点亮）
        f.write("        // 默认全 0（空白）\n")
        f.write("        begin : init_blank\n")
        f.write("            integer i;\n")
        f.write("            for (i = 0; i < 512; i = i + 1) mem[i] = 16'h0000;\n")
        f.write("        end\n")
        for i, v in enumerate(all_rows):
            f.write("        mem[%3d] = 16'h%04X;\n" % (i, v))
        f.write("    end\n\n")
        f.write("    always @(posedge clk) data <= mem[addr];\n\n")
        f.write("endmodule\n")

    print("已生成: %s" % os.path.abspath(OUT_V))

    # ---------------- 输出预览图 ----------------
    SCALE, COLS = 4, 6
    ROWS = (len(CHARS) + COLS - 1) // COLS
    PAD = 3
    cw, chh = CW*SCALE + PAD, CH*SCALE + PAD
    img = Image.new("RGB", (COLS*cw + PAD, ROWS*chh + PAD), (20, 30, 20))
    d = ImageDraw.Draw(img)
    for i, (ch, rows) in enumerate(char_map):
        cx = PAD + (i % COLS) * cw
        cy = PAD + (i // COLS) * chh
        for y, v in enumerate(rows):
            for x in range(CW):
                if v & (0x8000 >> x):
                    d.rectangle([cx+x*SCALE, cy+y*SCALE,
                                 cx+x*SCALE+SCALE-1, cy+y*SCALE+SCALE-1],
                                fill=(0, 255, 0))     # 绿色，与实际显示一致
    img.save(OUT_PNG)
    print("已生成预览图: %s" % os.path.abspath(OUT_PNG))


if __name__ == "__main__":
    main()
