#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mkicon.py — 纯 Python（无 PIL/numpy）生成 iOS 图标 + 对比图
      主画布 720x720 抗锯齿渲染，再整数倍盒式降采样到 180/120/60，
      避免低分辨率硬边（现有图标就是 60px 直接画了再放大，边缘有锯齿）。

用法:
    python mkicon.py preview     # 生成 proposals/ 下的方案图 + 对比图 contact.png
    python mkicon.py install A   # 把方案 A 写到 RealBG/AppIcon60x60*.png
"""
import zlib, struct, math, os, sys

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "proposals")


# ---------------------------------------------------------------- PNG 读写
def png_write(path, w, h, rows):
    """rows: list[h] of list[w] of (r,g,b,a) 0-255"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b, a = rows[y][x]
            raw += bytes((r & 255, g & 255, b & 255, a & 255))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def png_read(path):
    d = open(path, "rb").read()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp, stride = 4, w * 4
    out, prev, i = [], bytearray(stride), 0
    for y in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if f == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out.append([tuple(line[k:k + 3]) + (line[k + 3],) for k in range(0, stride, 4)])
        prev = line
    return w, h, out


# ---------------------------------------------------------------- 遮罩/绘制
def poly_mask(pts, S, ss=4):
    mask = [[0.0] * S for _ in range(S)]
    n = len(pts)
    for sy in range(S * ss):
        y = (sy + 0.5) / ss
        xs = []
        for i in range(n):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % n]
            if (y1 <= y < y2) or (y2 <= y < y1):
                xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        if not xs:
            continue
        xs.sort()
        row = mask[sy // ss]
        wgt = 1.0 / ss
        for k in range(0, len(xs) - 1, 2):
            xa, xb = max(0.0, xs[k]), min(float(S), xs[k + 1])
            if xb <= xa:
                continue
            for p in range(int(xa), min(int(xb) + 1, S)):
                cov = min(xb, p + 1) - max(xa, p)
                if cov > 0:
                    row[p] += cov * wgt
    return mask


def ring_mask(cx, cy, r, width, S, ss=3):
    mask = [[0.0] * S for _ in range(S)]
    lo, hi = r - width / 2.0 - 1, r + width / 2.0 + 1
    y0, y1 = max(0, int(cy - hi)), min(S, int(cy + hi) + 1)
    x0, x1 = max(0, int(cx - hi)), min(S, int(cx + hi) + 1)
    inv = 1.0 / (ss * ss)
    for y in range(y0, y1):
        for x in range(x0, x1):
            hit = 0
            for sy in range(ss):
                dy = y + (sy + 0.5) / ss - cy
                for sx in range(ss):
                    dx = x + (sx + 0.5) / ss - cx
                    d = math.hypot(dx, dy)
                    if lo <= d <= hi:
                        hit += 1
            if hit:
                mask[y][x] = hit * inv
    return mask


def round_mask(S, radius, ss=4):
    mask = [[0.0] * S for _ in range(S)]
    inv = 1.0 / (ss * ss)
    for y in range(S):
        for x in range(S):
            hit = 0
            for sy in range(ss):
                py = y + (sy + 0.5) / ss
                for sx in range(ss):
                    px = x + (sx + 0.5) / ss
                    cx = min(max(px, radius), S - radius)
                    cy = min(max(py, radius), S - radius)
                    if math.hypot(px - cx, py - cy) <= radius:
                        hit += 1
            if hit:
                mask[y][x] = hit * inv
    return mask


def blend(base, mask, color):
    r, g, b, a = color
    S = len(base)
    for y in range(S):
        row, mrow = base[y], mask[y]
        for x in range(S):
            m = mrow[x]
            if m <= 0.0:
                continue
            ma = a * m
            br, bg, bb, ba = row[x]
            na = ma + ba * (1 - ma)
            if na <= 0:
                row[x] = (0.0, 0.0, 0.0, 0.0)
                continue
            k = ba * (1 - ma)
            row[x] = ((r * ma + br * k) / na,
                      (g * ma + bg * k) / na,
                      (b * ma + bb * k) / na,
                      na)


def gradient(S, c0, c1):
    out = [[None] * S for _ in range(S)]
    for y in range(S):
        for x in range(S):
            t = (x * 0.55 + y * 0.45) / (S - 1)
            out[y][x] = (c0[0] + (c1[0] - c0[0]) * t,
                         c0[1] + (c1[1] - c0[1]) * t,
                         c0[2] + (c1[2] - c0[2]) * t,
                         1.0)
    return out


def glow(base, cx, cy, radius, color, strength):
    r, g, b = color
    S = len(base)
    for y in range(S):
        row = base[y]
        dy = y - cy
        for x in range(S):
            dx = x - cx
            d = math.hypot(dx, dy) / radius
            if d >= 1.0:
                continue
            k = (1.0 - d) ** 2 * strength
            br, bg, bb, ba = row[x]
            row[x] = (br + (r - br) * k, bg + (g - bg) * k, bb + (b - bb) * k, ba)


# ---------------------------------------------------------------- 图形
BOLT = [(0.58, 0.03), (0.19, 0.56), (0.45, 0.56), (0.38, 0.97), (0.81, 0.42), (0.54, 0.42)]


def bolt_pts(box, S):
    x0, y0, x1, y1 = box
    return [((x0 + (x1 - x0) * px) * S, (y0 + (y1 - y0) * py) * S) for px, py in BOLT]


def design(name, S=720):
    """返回 float RGBA 画布"""
    if name == "A":      # 深空绿：暗底 + 亮绿闪电
        base = gradient(S, (13, 34, 29), (4, 11, 10))
        glow(base, S * 0.40, S * 0.30, S * 0.95, (24, 130, 96), 0.55)
        blend(base, poly_mask(bolt_pts((0.255, 0.155, 0.755, 0.845), S), S), (48, 232, 158, 1))
    elif name == "B":    # 翠绿渐变：亮底 + 白闪电
        base = gradient(S, (58, 219, 160), (5, 116, 84))
        glow(base, S * 0.30, S * 0.22, S * 0.85, (180, 255, 220), 0.30)
        blend(base, poly_mask(bolt_pts((0.255, 0.155, 0.755, 0.845), S), S), (255, 255, 255, 1))
    elif name == "C":    # 加速环：暗底 + 绿环 + 白闪电
        base = gradient(S, (12, 20, 32), (6, 16, 16))
        glow(base, S * 0.5, S * 0.5, S * 0.75, (20, 120, 100), 0.45)
        blend(base, ring_mask(S * 0.5, S * 0.5, S * 0.335, S * 0.052, S), (48, 232, 158, 1))
        blend(base, poly_mask(bolt_pts((0.345, 0.235, 0.665, 0.765), S), S), (255, 255, 255, 1))
    else:                # ID：原图标
        raise SystemExit("unknown")
    return base


def downsample(base, factor):
    S = len(base)
    n = S // factor
    out = [[(0, 0, 0, 0)] * n for _ in range(n)]
    f2 = factor * factor
    for y in range(n):
        for x in range(n):
            r = g = b = a = 0.0
            for dy in range(factor):
                row = base[y * factor + dy]
                for dx in range(factor):
                    pr, pg, pb, pa = row[x * factor + dx]
                    r += pr * pa; g += pg * pa; b += pb * pa; a += pa
            if a <= 0:
                out[y][x] = (0, 0, 0, 0)
            else:
                out[y][x] = (int(r / a + .5), int(g / a + .5), int(b / a + .5), int(a / f2 + .5))
    return out


def to8(base):
    S = len(base)
    return [[(int(px[0] + .5), int(px[1] + .5), int(px[2] + .5), int(px[3] * 255 + .5))
             for px in row] for row in base]


# ---------------------------------------------------------------- 对比图
def paste(dst, src, ox, oy, mask=None):
    dh, dw = len(dst), len(dst[0])
    sh, sw = len(src), len(src[0])
    for y in range(sh):
        if oy + y < 0 or oy + y >= dh:
            continue
        for x in range(sw):
            if ox + x < 0 or ox + x >= dw:
                continue
            r, g, b, a = src[y][x]
            m = a / 255.0
            if mask is not None:
                m *= mask[y][x]
            if m <= 0:
                continue
            dr, dg, db, _ = dst[oy + y][ox + x]
            dst[oy + y][ox + x] = (int(r * m + dr * (1 - m)),
                                   int(g * m + dg * (1 - m)),
                                   int(b * m + db * (1 - m)), 255)


def resize(img, n):
    """面积平均缩放（img 为方形）"""
    S = len(img)
    out = [[(0, 0, 0, 0)] * n for _ in range(n)]
    scale = S / float(n)
    for y in range(n):
        sy0, sy1 = y * scale, (y + 1) * scale
        for x in range(n):
            sx0, sx1 = x * scale, (x + 1) * scale
            r = g = b = a = wsum = 0.0
            for sy in range(int(sy0), min(int(math.ceil(sy1)), S)):
                wy = min(sy1, sy + 1) - max(sy0, sy)
                for sx in range(int(sx0), min(int(math.ceil(sx1)), S)):
                    wx = min(sx1, sx + 1) - max(sx0, sx)
                    wgt = wy * wx
                    pr, pg, pb, pa = img[sy][sx]
                    r += pr * wgt; g += pg * wgt; b += pb * wgt; a += pa * wgt
                    wsum += wgt
            if wsum <= 0 or a <= 0:
                out[y][x] = (0, 0, 0, 0)
            else:
                out[y][x] = (int(r / wsum + .5), int(g / wsum + .5),
                             int(b / wsum + .5), int(a / wsum + .5))
    return out


def with_alpha(img):
    """统一成 (r,g,b,a) 0-255；原图标可能存在 alpha=0 的角"""
    return [[(p[0], p[1], p[2], p[3]) for p in row] for row in img]


def contact(cur180, variants, path):
    W, rowh = 620, 214
    H = rowh * (1 + len(variants)) + 16
    sheet = [[(15, 17, 21, 255)] * W for _ in range(H)]

    entries = [{180: cur180, 120: resize(cur180, 120), 60: resize(cur180, 60)}]
    entries += [variants[k] for k in sorted(variants)]

    for i, imgs in enumerate(entries):
        y0 = 16 + i * rowh
        for k, size in ((0, 180), (1, 120), (2, 60)):
            src = imgs[size]
            m = round_mask(size, int(round(size * 0.2237)), ss=3)
            x = 40 + {0: 0, 1: 290, 2: 460}[k]
            paste(sheet, src, x, y0 + (180 - size) // 2, m)
    png_write(path, W, H, sheet)


def save_all(name, outdir):
    base = design(name, 720)
    res = {}
    for size, fac in ((180, 4), (120, 6), (60, 12)):
        img = to8(downsample(base, fac))
        png_write(os.path.join(outdir, "icon_%s_%d.png" % (name, size)), size, size, img)
        res[size] = img
    return res


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "preview"
    here = os.path.dirname(os.path.abspath(__file__))
    appdir = os.path.join(os.path.dirname(here), "RealBG")

    if cmd == "install":
        name = sys.argv[2]
        base = design(name, 720)
        for size, fac, suffix in ((180, 4, "@3x"), (120, 6, "@2x"), (60, 12, "")):
            img = to8(downsample(base, fac))
            png_write(os.path.join(appdir, "AppIcon60x60%s.png" % suffix), size, size, img)
            print("wrote", "AppIcon60x60%s.png" % suffix, size)
        sys.exit(0)

    os.makedirs(OUT, exist_ok=True)
    variants = {}
    for v in ("A", "B", "C"):
        variants[v] = save_all(v, OUT)
        print("rendered", v)

    # 原图标（180）原样参与对比
    w, h, cur = png_read(os.path.join(appdir, "AppIcon60x60@3x.png"))
    print("current icon", w, h, "corner", cur[0][0], "center", cur[h // 2][w // 2])
    contact(cur, variants, os.path.join(OUT, "contact.png"))
    print("contact:", os.path.join(OUT, "contact.png"))
