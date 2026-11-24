#!/usr/bin/env python3
"""从 KKF0 字体里导出 ASCII 0x20-0x7E 的 8x16 原始点阵(给 64 位内核用).

用法: python3 tools/mkfont8x16.py font/font-kkf.bin build/font8x16.bin

KKF0 格式(见 font/README.md):
    头 16 字节: magic 'KKF0', version u32, count u32, data_off u32
    每个条目 12 字节: cp u32, w u8, h u8, pad u16, off u32(相对 data_off)
    字形数据: (w // 8) * h 字节,每行 1 字节,MSB 在最左

输出: 95 * 16 = 1520 字节,索引 = (ch - 0x20) * 16,每字形 16 行、
每行 1 字节(8 像素,MSB 在左)。缺失字形填 0(黑底)。
"""
import struct
import sys

GLYPH_W = 8
GLYPH_H = 16


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, 'rb').read()
    if data[:4] != b'KKF0':
        print(f'{src}: not a KKF0 file')
        return 1
    _version, count, data_off = struct.unpack_from('<III', data, 4)
    glyphs = {}
    for i in range(count):
        cp, w, h, _pad, off = struct.unpack_from('<IBBHI', data, 16 + i * 12)
        glyphs[cp] = (w, h, off)
    out = bytearray(95 * GLYPH_H)
    for ch in range(0x20, 0x7F):
        if ch not in glyphs:
            continue
        w, h, off = glyphs[ch]
        if w != GLYPH_W or h != GLYPH_H:
            # 只导出 8x16 的;别的尺寸跳过(ASCII 目前全是 8x16)
            continue
        raw = data[data_off + off:data_off + off + GLYPH_H]
        out[(ch - 0x20) * GLYPH_H:(ch - 0x20 + 1) * GLYPH_H] = raw
    open(dst, 'wb').write(out)
    print(f'{dst}: {len(out)} bytes ({95} glyphs, {GLYPH_W}x{GLYPH_H})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
