# -*- coding: utf-8 -*-
"""
打包给队友：只包含源码 + 约束 + TD 工程文件列表，不含编译产物。
由工程根目录的 4_打包给队友.bat 调用（bat 里只有英文，避免 GBK 乱码）。
"""
import os
import sys
import zipfile
import datetime

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

# 工程根目录 = 本脚本所在 tools 目录的上一级
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 桌面路径（用户桌面就在 C:\Users\<用户>\Desktop）
DESKTOP = os.path.join(os.environ.get('USERPROFILE', os.path.expanduser('~')), 'Desktop')

TS = datetime.datetime.now().strftime('%Y%m%d_%H%M')
OUT = os.path.join(DESKTOP, '广告牌_同步包_%s.zip' % TS)

# (工程内相对路径, 压缩包内路径)
ITEMS = [
    ('src/user_source/hdl_source',           'hdl_source'),
    ('src/user_source/constraints_source',   'constraints_source'),
    ('src/td_project/HDMI1.4b_Transmitter_v1.0.al',
                                             'HDMI1.4b_Transmitter_v1.0.al'),
]


def main():
    print('=' * 56)
    print('  打包给队友：源码 + 约束 + TD 工程文件（不含 Runs/文档）')
    print('=' * 56)

    n_files = 0
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for src_rel, arc_prefix in ITEMS:
            src = os.path.join(ROOT, src_rel)
            if os.path.isdir(src):
                for dirpath, _dirnames, filenames in os.walk(src):
                    for fn in filenames:
                        full = os.path.join(dirpath, fn)
                        rel = os.path.relpath(full, src)
                        z.write(full, os.path.join(arc_prefix, rel))
                        n_files += 1
            elif os.path.isfile(src):
                z.write(src, arc_prefix)
                n_files += 1
            else:
                print('  [警告] 找不到：%s' % src_rel)

    size_mb = os.path.getsize(OUT) / 1024 / 1024
    print('')
    print('  已生成：%s' % OUT)
    print('  文件数：%d，压缩包大小：%.1f MB' % (n_files, size_mb))
    print('')
    print('  队友解压后覆盖到他工程的：')
    print('    src\\user_source\\hdl_source\\')
    print('    src\\user_source\\constraints_source\\')
    print('    src\\td_project\\  （.al 工程文件）')
    print('  然后重新打开 .al 工程，确认工程树里有新模块，再综合。')
    print('=' * 56)


if __name__ == '__main__':
    main()
