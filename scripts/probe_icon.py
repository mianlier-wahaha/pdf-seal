#!/usr/bin/env python3
# 纯 Python PNG 解码 + 关键区域像素探针（无 PIL/外部依赖）
import zlib, struct, sys, math

def load_png(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    width = height = None
    bitd = colt = None
    idat = b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            width, height, bitd, colt = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    # colt 6 = RGBA, 8-bit
    assert colt == 6 and bitd == 8, f"unexpected colt={colt} bitd={bitd}"
    stride = width * 4
    # undo filtering
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if ftype == 1:  # Sub
            for i in range(stride):
                a = line[i-4] if i >= 4 else 0
                line[i] = (line[i] + a) & 0xff
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xff
        elif ftype == 3:  # Average
            for i in range(stride):
                a = line[i-4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xff
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i-4] if i >= 4 else 0
                b = prev[i]
                c = prev[i-4] if i >= 4 else 0
                pp = a + b - c
                pa = abs(pp - a); pb = abs(pp - b); pc = abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        out += line
        prev = line
    return width, height, out

def px(out, w, x, y):
    i = (y * w + x) * 4
    return out[i], out[i+1], out[i+2], out[i+3]

def count_in(out, w, h, x0, y0, x1, y1, pred):
    n = tot = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b, a = px(out, w, x, y)
            tot += 1
            if pred(r, g, b, a):
                n += 1
    return n, tot

def is_white(r, g, b, a):
    return a > 200 and r > 230 and g > 230 and b > 230
def is_gold(r, g, b, a):
    return a > 200 and r > 200 and g > 160 and b < 150 and r > b + 60
def is_red(r, g, b, a):
    return a > 200 and r > 120 and g < 90 and b < 90 and r > g + 40 and r > b + 40

path = sys.argv[1] if len(sys.argv) > 1 else "scripts/AppIcon_1024.png"
w, h, out = load_png(path)
print(f"size={w}x{h}")

# 1) 渐变：顶部 vs 底部背景红亮度
n_top, _ = count_in(out, w, h, 5, 5, 80, 80, is_red)
n_bot, _ = count_in(out, w, h, 5, h-80, 80, h-5, is_red)
def red_lum(out, w, h, x0, y0, x1, y1):
    s = 0; c = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b, a = px(out, w, x, y)
            if is_red(r, g, b, a):
                s += r; c += 1
    return s/c if c else 0
lum_top = red_lum(out, w, h, 5, 5, 80, 80)
lum_bot = red_lum(out, w, h, 5, h-80, 80, h-5)
print(f"red top lum={lum_top:.1f}  bot lum={lum_bot:.1f}  gradient={'YES' if lum_top > lum_bot + 3 else 'NO'}")

# 2) 金色印章（左下 70..250,70..250）
gold_n, gold_tot = count_in(out, w, h, 70, 70, 250, 250, is_gold)
print(f"gold seal pixels in (70..250)^2: {gold_n}/{gold_tot}  -> {'present' if gold_n > 80 else 'MISSING'}")

# 3) 白 PDF（右上 650..990, 740..900）
pdf_n, pdf_tot = count_in(out, w, h, 650, 740, 990, 900, is_white)
print(f"white PDF region (650..990,740..900): {pdf_n} white px  -> {'present' if pdf_n > 200 else 'MISSING'}")

# 4) 白 m（中心 280..720, 240..580）
m_n, m_tot = count_in(out, w, h, 280, 240, 720, 580, is_white)
print(f"white m region (280..720,240..580): {m_n} white px  -> {'present' if m_n > 1500 else 'MISSING'}")

# 总色彩数（量化）
from collections import Counter
cnt = Counter()
for y in range(0, h, 2):
    for x in range(0, w, 2):
        r, g, b, a = px(out, w, x, y)
        cnt[(r//16, g//16, b//16)] += 1
print(f"quantized colors (approx): {len(cnt)}")
