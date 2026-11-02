# -*- coding: utf-8 -*-
"""
一键同步到 GitHub：git add -A → commit → push
由工程根目录的 5_同步到GitHub.bat 调用。
"""
import os
import sys
import subprocess
import datetime

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True,
                          text=True, encoding='utf-8', errors='replace')


def main():
    print('=' * 56)
    print('  同步到 GitHub（E:\\project qianrushi\\anlu\\lab_ex5_i2s）')
    print('=' * 56)

    # ① 暂存所有改动
    run(['git', 'add', '-A'])

    # ② 检查是否有改动
    st = run(['git', 'status', '--porcelain'])
    if not st.stdout.strip():
        print('  没有需要同步的改动（工作区是干净的）。')
        return

    # ③ 提交
    msg = 'auto sync ' + datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    c = run(['git', 'commit', '-m', msg])
    print('  提交：%s' % msg)
    if c.returncode != 0:
        print(c.stdout)
        print(c.stderr)
        print('  提交失败，请检查上面的信息。')
        sys.exit(1)

    # ④ 推送
    print('  正在推送到 GitHub ...')
    p = run(['git', 'push'])
    if p.returncode != 0:
        print(p.stdout)
        print(p.stderr)
        print('')
        print('  推送失败。常见原因：')
        print('   1) Clash Verge 没开 → 打开后重试（代理已配置 127.0.0.1:7897）')
        print('   2) 远程有别人的新提交 → 先执行 git pull，再重试')
        print('   3) 需要登录 → 首次推送时按弹窗登录 GitHub')
        sys.exit(1)

    print('')
    print('  同步完成 ✅')
    print('  仓库：https://github.com/wyt-wuming/smart-adboard-eg4s20')


if __name__ == '__main__':
    main()
