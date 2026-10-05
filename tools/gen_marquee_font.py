# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : gen_marquee_font.py
 功能   : 生成"底部传送带字幕"用的 16x16 点阵字库 + 字符码点映射表
------------------------------------------------------------------------------
 【为什么要有这个脚本】
   FPGA 内部只有 72KB 的 ERAM，装不下完整汉字库（2 万字需要 640KB）。
   所以做法是：挑一批"常用字"，预先烧成点阵字库放进 FPGA。
   这个脚本就是干这个的：把汉字渲染成 16x16 点阵 → 输出成 Verilog 常量数组。

 【输出文件】
   1) src/user_source/hdl_source/video/marquee_font.v
        点阵字库 ROM
        地址 = 字符索引 * 16 + 行号(0~15)
        数据 = 该行 16 个像素，bit15 在最左边

   2) src/user_source/hdl_source/video/marquee_cmap.v
        码点映射表 ROM（按 Unicode 码点从小到大排序）
        txt_read.v 收到一个 Unicode 码点后，在这张表里查位置 p，
        则该字的字库索引 = IDX_CN_BASE + p

   3) tools/preview_marquee_font.png
        字模预览图，肉眼检查字形有没有糊掉

 【字符编码方式（重要）】
   索引 0        : 空白（查不到的字 或 空格，都显示成空白）
   索引 1  ~ 95  : ASCII 0x20 ~ 0x7E（空格、数字、字母、标点）
                   换算关系：索引 = 码点 - 31
   索引 96 ~     : 常用汉字（按 Unicode 码点升序排列）
                   换算关系：索引 = 96 + 在 cmap 表里的位置

 【用法】
   python tools/gen_marquee_font.py
   改完字表后重新运行即可（然后要重新编译 FPGA 工程）

 【ERAM 占用估算】
   每个汉字 = 16 行 x 16 bit = 256 bit
   一块 ERAM = 9 Kbit = 9216 bit，能装 36 个汉字
   本脚本目前约 700 字 -> 约 20 块 ERAM（板子共 64 块，空余 41 块）
==============================================================================
"""
import os
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------------------
# 字体设置
# ---------------------------------------------------------------------------
FONT_PATH = r"C:\Windows\Fonts\simhei.ttf"   # 黑体，点阵显示清楚
FONT_SIZE = 16
CW, CH = 16, 16                              # 字符宽高
OFF_X, OFF_Y = 0, 0

BASE = os.path.dirname(os.path.abspath(__file__))
HDLDIR = os.path.join(BASE, "..", "src", "user_source", "hdl_source", "video")
OUT_FONT  = os.path.join(HDLDIR, "marquee_font.v")
OUT_CMAP  = os.path.join(HDLDIR, "marquee_cmap.v")
OUT_PNG   = os.path.join(BASE, "preview_marquee_font.png")

IDX_CN_BASE = 96          # 汉字索引从这里开始
FONT_ROM_DEPTH = 16384    # 字库 ROM 深度 = 1024 字 x 16 行


# ---------------------------------------------------------------------------
# 【常用汉字表】—— 想加字就往下面这几个字符串里加，重复的字会自动去重
#    建议：按主题分组，方便以后查找和扩充
# ---------------------------------------------------------------------------
CN_CHARS = (
    # ---- 数字 / 单位 / 时间 ----
    "零一二三四五六七八九十百千万亿两半多少第全"
    "年月日时分秒周星期天号点刻钟早晚上下午夜今明昨"
    "个只件条张片块台部位名员们次回遍趟顿"
    "米厘毫分寸尺丈里斤吨克升毫升度摄氏"
    "元角分钱块折优惠价贵便宜"

    # ---- 常用代词/副词/连词/介词 ----
    "我你他她它们咱自己这那哪谁什么怎怎样如何"
    "是不的了吗呢吧啊哦呀嘛也就都还又再才只"
    "很太更最非常特别十分极其相当比较稍微"
    "和与及或但而且因为所以如果虽然但是因此"
    "在从到向往对于关于为了通过根据按照"
    "有没无不要会能可以必须应该需要得着过"
    "一直总是经常偶尔立刻马上已经曾经将要"
    "一起同样相互彼此各自分别全部所有每各"

    # ---- 常用动词 ----
    "来去回进出口上下走动跑飞来往返回离开到达"
    "看听读写说讲问答告诉叫喊念唱谈聊"
    "吃喝穿住用做干搞弄拿放取给送买卖"
    "想爱喜欢恨怕希望愿意打算计划决定选择"
    "开始结束完成继续停止变化发展提高增长减少"
    "打开关闭启动运行操作使用方法步骤设置调整"
    "显示播放暂停转动切换更新下载上传保存"
    "制作创造设计研发生产制造加工安装维修"
    "帮助支持服务提供满足保证确保实现达成"
    "感谢欢迎祝贺庆祝祝福问候邀请参加"

    # ---- 广告 / 商业高频字 ----
    "广告牌智能数字媒体展示系统平台方案"
    "安路科技股份有限公司企业工厂商家店铺"
    "欢迎光临谢谢惠顾再次光顾谢谢关照"
    "新品上市限时优惠特价促销热卖推荐"
    "品质保证服务第一诚信经营顾客至上"
    "专业团队创新设计匠心制造精选好物"
    "超值实惠全场包邮免费配送货到付款"
    "二十四小时营业时间地址电话联系"
    "方式订购咨询客服售后保修退换"
    "正品官方旗舰专卖授权代理经销"
    "品牌名牌高端顶级豪华经典时尚"
    "新款流行潮流前沿科技智能先进"
    "节能环保绿色健康安全放心可靠"
    "质量数量价格成本利润收益回报"
    "活动期间赠品礼包抽奖中奖领取"
    "会员积分红包折扣满减秒杀抢购"
    "限量独家首发预售到货通知"
    "周年庆典开业大吉隆重举行"
    "诚聘英才招工招聘求职简历"
    "房产汽车家电手机电脑服饰"
    "食品餐饮酒店旅游教育医疗"
    "金融保险投资理财贷款"
    "装修建材家具灯具厨卫"
    "运动健身美容美发摄影"
    "图书文具玩具母婴宠物"
    "农资五金机电器械工具"

    # ---- 世界计划 / 二次元相关（给 UP 主自己留的彩蛋）----
    "世界计划初音未来虚拟歌手音乐节奏"
    "演唱会舞台歌曲旋律梦想青春校园"
    "星乃一歌花里みのり"       # 注意：日文假名若渲染为空白属正常
    "桐谷遥桃井愛莉日野森雫"
    "白石杏小豆沢こはね東雲彰人青柳冬弥"
    "天馬司鳳えむ草薙寧々神代類"
    "宵崎奏朝比奈まふゆ東雲絵名暁山瑞希"
    "巡音流歌镜音双子"

    # ---- 通用名词 ----
    "人人民众大家朋友客户用户消费者观众"
    "世界国家城市乡村地方区域中国外国"
    "家家庭房屋室内户外建筑楼道路桥"
    "天空地山水河海江河湖季节春风夏雨秋"
    "冬雪日月星云阳光明亮暗夜色景象"
    "花草树木叶果菜粮食肉鱼鸟兽虫"
    "手眼耳鼻口心头面身体力气精神心情"
    "话语言文字词句子篇章节目内容"
    "事情物件东西材料工具机器设备"
    "工作学习生活休息娱乐运动健康疾病"
    "学校老师学生孩子父母兄弟姐妹妹"
    "朋友同学同事领导员工老板经理"
    "钱财富贵贫穷困难容易简单复杂"
    "问题办法结果原因条件环境影响"
    "方向位置距离速度重量长度宽度高度"
    "颜色红黄蓝绿白黑灰紫粉橙青棕"
    "大小高低长短粗细宽窄厚薄轻重"
    "新旧好坏美丑快慢早晚冷热干湿"
    "前后左右上下里外中间旁边附近"
    "东南西北正面背面侧面顶部底部"
    "第一最后其次再次另外此外同时"
    "百分之倍翻番增长下降持平"
)


def build_charset():
    """构造最终字符表：索引 0 = 空白，1~95 = ASCII，96+ = 汉字"""
    chars = [' ']                                  # 索引 0：空白
    for c in range(0x20, 0x7F):                    # 索引 1~95：ASCII
        chars.append(chr(c))

    seen = set(chars)
    cn = []
    for ch in CN_CHARS:
        if ch in seen:
            continue
        if ord(ch) > 0xFFFF:
            continue                                # 跳过 BMP 之外的生僻字
        seen.add(ch)
        cn.append(ch)

    cn.sort(key=ord)                                # 按码点排序（查表要用）
    chars.extend(cn)
    return chars, cn


def render(ch, font):
    """把字符渲染成 16 行 x 16 bit 的点阵"""
    img = Image.new("1", (CW, CH), 0)
    ImageDraw.Draw(img).text((OFF_X, OFF_Y), ch, font=font, fill=1)
    px = img.load()
    rows = []
    for y in range(CH):
        v = 0
        for x in range(CW):
            if px[x, y]:
                v |= (0x8000 >> x)               # MSB 在最左
        rows.append(v)
    return rows


def write_font_v(all_rows, total_chars, cn_count):
    lines = []
    a = lines.append
    a("//==============================================================================")
    a("//  文件名  : marquee_font.v   （由 tools/gen_marquee_font.py 自动生成，请勿手改）")
    a("//  功能    : 底部传送带字幕用的 16x16 点阵字库")
    a("//------------------------------------------------------------------------------")
    a("//  地址 = 字符索引 * 16 + 行号(0~15)，即 {索引[13:4]..., 行号[3:0]}")
    a("//  数据 = 该行 16 个像素，bit15 在最左边（屏幕上最左）")
    a("//")
    a("//  索引 0        : 空白")
    a("//  索引 1  ~ 95  : ASCII 0x20~0x7E")
    a("//  索引 96 ~ %-4d: 常用汉字（按 Unicode 码点升序）" % (IDX_CN_BASE + cn_count - 1))
    a("//")
    a("//  本字库共 %d 个字符，占 ROM %d x 16bit" % (total_chars, FONT_ROM_DEPTH))
    a("//  改字表请编辑 tools/gen_marquee_font.py 顶部的 CN_CHARS 后重新运行")
    a("//==============================================================================")
    a("")
    a("module marquee_font (")
    a("    input  wire        clk,        // 视频时钟 25MHz")
    a("    input  wire [13:0] addr,       // {字符索引, 行号}  最大 1023*16+15")
    a("    output reg  [15:0] data        // 该行的 16 个像素")
    a(");")
    a("")
    a("    reg [15:0] mem [0:%d];" % (FONT_ROM_DEPTH - 1))
    a("")
    a("    initial begin")
    a("        // 全部先清 0（空白），再把有字的地址填进去")
    a("        begin : init_blank")
    a("            integer i;")
    a("            for (i = 0; i < %d; i = i + 1) mem[i] = 16'h0000;" % FONT_ROM_DEPTH)
    a("        end")
    # 每行写 4 个赋值，缩小文件体积
    for i in range(0, len(all_rows), 4):
        chunk = all_rows[i:i+4]
        s = "        "
        for j, v in enumerate(chunk):
            s += "mem[%5d] = 16'h%04X; " % (i + j, v)
        a(s.rstrip())
    a("    end")
    a("")
    a("    always @(posedge clk) data <= mem[addr];")
    a("")
    a("endmodule")
    with open(OUT_FONT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_cmap_v(cn):
    lines = []
    a = lines.append
    a("//==============================================================================")
    a("//  文件名  : marquee_cmap.v   （由 tools/gen_marquee_font.py 自动生成，请勿手改）")
    a("//  功能    : Unicode 码点 -> 字库索引 的映射表（按码点升序排列）")
    a("//------------------------------------------------------------------------------")
    a("//  txt_read.v 从 txt 文件里解出一个汉字的 Unicode 码点后，")
    a("//  在这张表里逐条比较，找到它在第 p 条，")
    a("//  则字库索引 = %d + p" % IDX_CN_BASE)
    a("//")
    a("//  查表是上电时只做一次的活儿，慢一点没关系：")
    a("//  每字最多 %d 拍 x 10ns = %d us" % (len(cn), len(cn) * 10 // 1000 + 1))
    a("//==============================================================================")
    a("")
    a("module marquee_cmap (")
    a("    input  wire        clk,        // 100MHz（SD 时钟域）")
    a("    input  wire [9:0]  addr,       // 表项序号 0 ~ %d" % (len(cn) - 1))
    a("    output reg  [15:0] code        // 该条目的 Unicode 码点")
    a(");")
    a("")
    a("    reg [15:0] mem [0:%d];" % (max(len(cn) - 1, 0)))
    a("")
    a("    initial begin")
    for i, ch in enumerate(cn):
        a("        mem[%3d] = 16'h%04X;   // %s" % (i, ord(ch), ch))
    a("    end")
    a("")
    a("    always @(posedge clk) code <= mem[addr];")
    a("")
    a("endmodule")
    with open(OUT_CMAP, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_preview(char_map):
    SCALE, COLS = 3, 16
    n = len(char_map)
    ROWS = (n + COLS - 1) // COLS
    PAD = 2
    cw, chh = CW*SCALE + PAD, CH*SCALE + PAD
    img = Image.new("RGB", (COLS*cw + PAD, ROWS*chh + PAD), (16, 20, 16))
    d = ImageDraw.Draw(img)
    for i, (ch, rows) in enumerate(char_map):
        cx = PAD + (i % COLS) * cw
        cy = PAD + (i // COLS) * chh
        for y, v in enumerate(rows):
            for x in range(CW):
                if v & (0x8000 >> x):
                    d.rectangle([cx+x*SCALE, cy+y*SCALE,
                                 cx+x*SCALE+SCALE-1, cy+y*SCALE+SCALE-1],
                                fill=(120, 255, 120))
    img.save(OUT_PNG)


def main():
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    chars, cn = build_charset()
    print("ASCII 字符: %d 个 (索引 1~95)" % 95)
    print("汉字      : %d 个 (索引 %d~%d)" % (len(cn), IDX_CN_BASE, IDX_CN_BASE + len(cn) - 1))
    print("字符总数  : %d" % len(chars))

    need_rows = len(chars) * 16
    if need_rows > FONT_ROM_DEPTH:
        raise SystemExit("!! 字符太多，ROM 深度 %d 不够用（需要 %d）" % (FONT_ROM_DEPTH, need_rows))

    all_rows, char_map = [], []
    empty = []
    for ch in chars:
        rows = render(ch, font)
        if ch != ' ' and not any(rows):
            empty.append(ch)
        char_map.append((ch, rows))
        all_rows.extend(rows)
    # 补 0 到 ROM 深度
    all_rows.extend([0] * (FONT_ROM_DEPTH - len(all_rows)))

    write_font_v(all_rows, len(chars), len(cn))
    write_cmap_v(cn)
    write_preview(char_map)

    print("已生成: %s" % os.path.abspath(OUT_FONT))
    print("已生成: %s" % os.path.abspath(OUT_CMAP))
    print("已生成: %s" % os.path.abspath(OUT_PNG))
    print("")
    print("【支持的汉字】")
    print("".join(cn))
    if empty:
        print("")
        print("【注意】以下字符渲染出来是空白的（可能是日文假名/生僻字，不影响使用）:")
        print("".join(empty))


if __name__ == "__main__":
    main()
