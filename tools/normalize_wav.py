# -*- coding: utf-8 -*-
"""
==============================================================================
 文件名 : normalize_wav.py
 功能   : 把任意 WAV 转成 FPGA 能播的格式
           目标格式 = 48000 Hz / 16 bit / 立体声 / 标准 44 字节头
------------------------------------------------------------------------------
 用法   : python normalize_wav.py 输入.wav [输出.wav]

 为什么必须 48kHz:
     FPGA 里的音频 PLL 只能产生 12.288 MHz 主时钟，
     它正好等于 48kHz x 256，所以采样率只能是 48kHz。
     另外 HDMI 的 ACR 参数(N=6144)和发射核配置也都是按 48kHz 写死的。
     采样率不对的话，声音会变速变调（像快放/慢放）。

 为什么要重写成标准头:
     FPGA 里的 wav_read 模块只认 44 字节的标准 RIFF 头。
     很多软件导出的 WAV 是 WAVE_FORMAT_EXTENSIBLE (0xFFFE) 或带
     LIST/fact 等额外 chunk，偏移量不是 44，会解析失败。
     这里统一重写成最干净的格式。

 重采样用 audioop.ratecv（Python 标准库，C 实现，速度快、质量够用）
==============================================================================
"""
import sys, os, struct, audioop, wave


def parse_wav(path):
    """手工解析 WAV，兼容 WAVE_FORMAT_EXTENSIBLE 和各种多余 chunk"""
    data = open(path, 'rb').read()
    if data[0:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise ValueError('不是 RIFF/WAVE 文件')

    fmt = None
    audio = None
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        csz = struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8: pos + 8 + csz]

        if cid == b'fmt ':
            tag, ch, rate, bps, align, bits = struct.unpack('<HHIIHH', body[:16])
            if tag == 0xFFFE and len(body) >= 40:
                sub = struct.unpack('<H', body[24:26])[0]
                if sub != 1:
                    raise ValueError('子格式不是 PCM(1)，而是 %d —— 请先转成 PCM WAV' % sub)
            elif tag != 1:
                raise ValueError('不是 PCM 格式(tag=%d) —— 请先转成 PCM WAV' % tag)
            fmt = dict(ch=ch, rate=rate, bits=bits)
        elif cid == b'data':
            audio = body
        pos += 8 + csz + (csz & 1)

    if fmt is None or audio is None:
        raise ValueError('缺少 fmt 或 data chunk')
    return fmt, audio


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + '_48k.wav'

    print('读取: %s' % src)
    fmt, audio = parse_wav(src)
    print('  原始格式: %d Hz / %d bit / %d 声道 / %.2f 秒'
          % (fmt['rate'], fmt['bits'], fmt['ch'],
             len(audio) / (fmt['rate'] * fmt['ch'] * fmt['bits'] // 8)))

    if fmt['bits'] != 16:
        raise ValueError('只支持 16bit（当前 %d bit）' % fmt['bits'])

    # ---- 重采样到 48kHz ----
    if fmt['rate'] != 48000:
        print('  重采样: %d Hz -> 48000 Hz ...' % fmt['rate'])
        audio, _ = audioop.ratecv(audio, 2, fmt['ch'], fmt['rate'], 48000, None)
    else:
        print('  采样率已是 48kHz，无需重采样')

    # ---- 单声道转立体声（FPGA 端按立体声打包，单声道会只响一边）----
    if fmt['ch'] == 1:
        print('  单声道 -> 立体声')
        audio = audioop.tostereo(audio, 2, 1, 1)
        fmt['ch'] = 2
    elif fmt['ch'] != 2:
        raise ValueError('只支持 1 或 2 声道（当前 %d）' % fmt['ch'])

    # ---- 写标准 44 字节头的 WAV ----
    with wave.open(dst, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(audio)

    # ---- 校验输出 ----
    w = wave.open(dst, 'rb')
    n = w.getnframes()
    print('')
    print('输出: %s' % dst)
    print('  大小    : %.2f MB' % (os.path.getsize(dst) / 1024 / 1024))
    print('  格式    : %d Hz / %d bit / %d 声道'
          % (w.getframerate(), w.getsampwidth() * 8, w.getnchannels()))
    print('  时长    : %.1f 秒' % (n / w.getframerate()))
    print('  数据字节: %d' % (n * 4))
    print('  头长    : %d 字节 (标准应为 44)' % (os.path.getsize(dst) - n * 4))
    w.close()
    print('')
    print('[OK] 转换完成，把这个文件拷到 TF 卡根目录即可')


if __name__ == '__main__':
    main()
