#!/usr/bin/env python3
"""Make the theme previews in tests/fixtures/previews/ (684x267 WebP), one per theme in tests/fixtures/themes.json,
drawn here from that theme's own colours: synthetic stand-ins with no outside artwork, laid out the way the engine's
previews are (the five fan screens top left, the pump top right, the 8.8" strip below, with a clock and readings).
tests/ui/make-thumbs.py cuts the screen thumbnails from them. Needs Pillow and numpy; the outputs are committed, so
the tests need neither. The same input makes the same pictures (each theme seeds its own random numbers).

  python3 tests/fixtures/previews/make.py
"""
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
W, H = 684, 267
FAN = 94
PUMP = (201, 94)
STRIP = (684, 170)
BLACK = np.zeros(3)
WHITE = np.full(3, 255.0)

# The look each theme's stand-in takes, by name; a theme not listed gets the plain glow.
KIND = {'abyss': 'ocean', 'arctic': 'aurora', 'cyberpunk': 'city', 'deep-orange': 'dunes', 'gilded-noir': 'deco',
        'hellfire': 'fire', 'matrix': 'rain', 'omarchy-oxblood-parchment': 'parchment', 'sakura': 'blossom',
        'stealth': 'carbon', 'synthwave': 'synthwave', 'toxic': 'toxic'}


def rgb(value):
    return np.array([int(value[i:i + 2], 16) for i in (1, 3, 5)], float)


def mix(a, b, t):
    return a + (b - a) * t


def font(size):
    return ImageFont.load_default(size=size)


def image(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGB')


def array(img):
    return np.asarray(img.convert('RGB'), float)


def vgrad(w, h, stops):
    """A vertical gradient through [(position 0-1, colour)]."""
    y = np.linspace(0, 1, h)
    pos = [p for p, _ in stops]
    cols = np.array([c for _, c in stops])
    ch = [np.interp(y, pos, cols[:, k]) for k in range(3)]
    return np.repeat(np.stack(ch, axis=1)[:, None, :], w, axis=1)


def noise(rng, w, h, sx, sy=None, octaves=3):
    """Smooth value noise in 0-1, cell size sx by sy pixels."""
    sy = sy or sx
    out, amp, total = np.zeros((h, w)), 1.0, 0.0
    for o in range(octaves):
        gw, gh = int(w / (sx / 2 ** o)) + 3, int(h / (sy / 2 ** o)) + 3
        cells = Image.fromarray((rng.random((gh, gw)) * 255).astype(np.uint8), 'L')
        out += np.asarray(cells.resize((w, h), Image.BICUBIC), float) / 255 * amp
        total += amp
        amp *= 0.5
    return out / total


def light(base, layer, blur, strength=1.0, core=1.0):
    """Add a light layer (an RGB image on black) to base, with a soft glow of it around."""
    halo = array(layer.filter(ImageFilter.GaussianBlur(blur))) if blur else 0
    return np.clip(base + array(layer) * core + halo * strength, 0, 255)


def layer(w, h):
    img = Image.new('RGB', (w, h), 'black')
    return img, ImageDraw.Draw(img)


def col(c, k=1.0):
    return tuple(int(v) for v in np.clip(c * k, 0, 255))


def radial(w, h, cx, cy, r):
    y, x = np.mgrid[0:h, 0:w]
    return np.clip(1 - np.hypot(x - cx, y - cy) / r, 0, 1)


def ridge(rng, w, base, amp, cell):
    return base + (noise(rng, w, 1, cell, 1, octaves=4)[0] - 0.5) * 2 * amp


# ---------------------------------------------------------------- scenes, any size


def ocean(w, h, pal, rng):
    a, b = pal[0], pal[1]
    out = vgrad(w, h, [(0, mix(b, BLACK, 0.55)), (0.45, mix(b, BLACK, 0.82)), (1, np.array([2, 4, 10.0]))])
    rays, d = layer(w, h)
    for _ in range(max(3, w // 90)):
        x0, dx, half = rng.uniform(0, w), rng.uniform(-0.6, 0.6) * h, rng.uniform(4, 14)
        d.polygon([(x0 - half, 0), (x0 + half, 0), (x0 + dx + half * 4, h), (x0 + dx - half * 4, h)], fill=col(a, 0.22))
    out = light(out, rays, h / 10, 1.2, 0.3)
    for _ in range(3):
        out += radial(w, h, rng.uniform(0, w), rng.uniform(0.3, 0.9) * h, rng.uniform(0.15, 0.3) * h)[..., None] ** 2 * a * 0.35
    dots, d = layer(w, h)
    for _ in range(w * h // 700):
        x, y, r = rng.uniform(0, w), rng.uniform(0, h), rng.choice([0.6, 1, 1.4])
        d.ellipse((x - r, y - r, x + r, y + r), fill=col(mix(a, WHITE, 0.4), rng.uniform(0.3, 0.9)))
    return light(out, dots, 2, 0.8)


def aurora(w, h, pal, rng):
    out = vgrad(w, h, [(0, np.array([4, 8, 24.0])), (0.55, mix(pal[5], BLACK, 0.78)), (1, mix(pal[1], BLACK, 0.55))])
    stars, d = layer(w, h)
    for _ in range(w * h // 260):
        x, y = rng.uniform(0, w), rng.uniform(0, 0.65) * h
        d.point((x, y), fill=col(WHITE, rng.uniform(0.25, 0.8)))
    out = light(out, stars, 0.8, 0.6)
    y, x = np.mgrid[0:h, 0:w]
    phase = rng.uniform(0, 6.28)
    top = h * (0.18 + 0.1 * np.sin(x[0] / w * 6.28 * 1.2 + phase)) + (noise(rng, w, 1, w / 6, 1)[0] - 0.5) * h * 0.2
    depth = (y - top[None, :]) / (h * 0.32)
    curtain = np.where(depth > 0, np.exp(-depth * 2.2), np.exp(depth * 9)) * (0.35 + 0.65 * noise(rng, w, h, 6, h * 2, 2))
    tint = mix(pal[2], pal[0], np.clip(depth, 0, 1)[..., None])
    out = np.clip(out + curtain[..., None] * tint * 0.8, 0, 255)
    far, near = ridge(rng, w, h * 0.74, h * 0.16, w / 5), ridge(rng, w, h * 0.88, h * 0.1, w / 8)
    snow = vgrad(w, h, [(0, pal[0]), (0.62, mix(pal[0], BLACK, 0.25)), (0.82, mix(pal[1], BLACK, 0.45)),
                        (1, mix(pal[5], BLACK, 0.7))])
    out = np.where((y >= far[None, :])[..., None], snow * (0.75 + 0.25 * noise(rng, w, h, 5)[..., None]), out)
    return np.where((y >= near[None, :])[..., None], mix(pal[5], BLACK, 0.86), out)


def city(w, h, pal, rng):
    magenta, cyan = rgb('#ff00ff'), pal[0]
    out = vgrad(w, h, [(0, np.array([8, 0, 16.0])), (0.55, mix(pal[1], BLACK, 0.45)), (0.78, mix(pal[2], BLACK, 0.25)),
                       (1, np.array([6, 0, 12.0]))])
    out += radial(w, h, w * 0.6, h * 0.8, h * 0.9)[..., None] ** 2 * pal[2] * 0.35
    back, d = layer(w, h)
    x = 0.0
    while x < w:
        bw, bh = rng.uniform(10, 30), rng.uniform(0.25, 0.7) * h
        d.rectangle((x, h - bh, x + bw, h), fill=(34, 8, 52))
        x += bw + rng.uniform(1, 4)
    out = np.where(array(back) > 0, array(back), out)
    front, d = layer(w, h)
    signs, s = layer(w, h)
    x = rng.uniform(-10, 0)
    while x < w:
        bw, bh = rng.uniform(14, 40), rng.uniform(0.15, 0.5) * h
        d.rectangle((x, h - bh, x + bw, h), fill=(6, 1, 10))
        for wy in np.arange(h - bh + 4, h - 2, 4):
            for wx in np.arange(x + 3, x + bw - 2, 4):
                if rng.random() < 0.18:
                    d.point((wx, wy), fill=col(cyan if rng.random() < 0.6 else magenta, rng.uniform(0.5, 1)))
        if rng.random() < 0.3:
            sx = x + bw / 2
            s.line((sx, h - bh - rng.uniform(4, 14), sx, h - bh), fill=col(magenta if rng.random() < 0.5 else cyan), width=2)
        x += bw + rng.uniform(0, 3)
    front_a = array(front)
    lit = front_a.max(axis=2) > 0
    out = np.where(lit[..., None], front_a, out)
    out = light(out, signs, 3, 1.4)
    out[::3] *= 0.86
    return out


def dunes(w, h, pal, rng):
    out = vgrad(w, h, [(0, mix(pal[1], BLACK, 0.85)), (0.35, mix(pal[2], BLACK, 0.45)), (0.62, mix(pal[4], WHITE, 0.1)),
                       (1, mix(pal[1], BLACK, 0.6))])
    sun, d = layer(w, h)
    cx, cy, r = w * 0.66, h * 0.58, h * 0.24
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=col(mix(pal[4], WHITE, 0.55)))
    out = light(out, sun, h * 0.18, 1.3)
    y = np.mgrid[0:h, 0:w][0]
    for k, (base, amp, shade) in enumerate([(0.66, 0.08, 0.55), (0.78, 0.07, 0.72), (0.9, 0.05, 0.86)]):
        line = ridge(rng, w, h * base, h * amp, w / (3 + 2 * k))
        tone = mix(pal[k + 1], BLACK, shade)
        out = np.where((y >= line[None, :])[..., None], tone * (0.9 + 0.1 * noise(rng, w, h, 3)[..., None]), out)
    return out


def deco(w, h, pal, rng):
    gold, deep = mix(pal[5], WHITE, 0.15), pal[1]
    out = vgrad(w, h, [(0, np.array([10, 7, 4.0])), (1, np.array([22, 12, 5.0]))])
    lines, d = layer(w, h)
    cx, cy = w * 0.62, h * 1.02
    for k in range(28):
        ang = math.pi * (k + 0.5) / 28
        d.line((cx, cy, cx + math.cos(ang) * w, cy - math.sin(ang) * w), fill=col(gold, 0.32), width=1)
    for r in np.arange(h * 0.3, h * 1.6, h * 0.16):
        d.arc((cx - r, cy - r, cx + r, cy + r), 180, 360, fill=col(gold, 0.6), width=1)
    for yy in (4, 8, h - 9, h - 5):
        d.line((0, yy, w, yy), fill=col(gold, 0.7), width=1)
    out = light(out, lines, 3, 0.9)
    out += radial(w, h, cx, h * 0.85, h * 0.9)[..., None] ** 2 * deep * 0.4
    return out


def fire(w, h, pal, rng):
    y = np.linspace(1, 0, h)[:, None]
    n = noise(rng, w, h, 22, 34, 4)
    heat = np.clip(n * 1.45 - y * 1.25 + 0.05, 0, 1) ** 1.4
    stops = [(0, BLACK), (0.25, rgb('#3a0002')), (0.45, pal[1]), (0.65, pal[0]), (0.85, pal[4]), (1, rgb('#ffd86a'))]
    pos = [p for p, _ in stops]
    cols = np.array([c for _, c in stops])
    out = np.stack([np.interp(heat, pos, cols[:, k]) for k in range(3)], axis=-1)
    embers, d = layer(w, h)
    for _ in range(w * h // 900):
        x, yy, r = rng.uniform(0, w), rng.uniform(0, 0.7) * h, rng.choice([0.6, 1.0, 1.4])
        d.ellipse((x - r, yy - r, x + r, yy + r), fill=col(rgb('#ffae00'), rng.uniform(0.4, 1)))
    return light(out, embers, 2, 1.0)


def rain(w, h, pal, rng):
    out = vgrad(w, h, [(0, np.array([0, 4, 1.0])), (1, mix(pal[5], BLACK, 0.55))])
    glyphs, d = layer(w, h)
    heads, e = layer(w, h)
    size = 11
    f = font(size)
    chars = '0123456789ABCDEFXZ:=+<>'
    for x in range(2, w, 10):
        head, trail = rng.uniform(-0.2, 1.2) * h, rng.uniform(0.25, 0.8) * h
        yy = head
        k = 0
        while yy > -size and yy > head - trail:
            t = (head - yy) / trail
            c = mix(pal[1], pal[5], t)
            d.text((x, yy), chars[int(rng.integers(len(chars)))], font=f, fill=col(c, 1 - 0.7 * t))
            if k == 0:
                e.text((x, yy), chars[int(rng.integers(len(chars)))], font=f, fill=col(pal[0]))
            yy -= size + 1
            k += 1
    return light(light(out, glyphs, 1.5, 0.5), heads, 3, 1.2)


def parchment(w, h, pal, rng):
    ink = mix(pal[0], BLACK, 0.6)
    paper = vgrad(w, h, [(0, rgb('#f2e7cf')), (1, rgb('#e2cea6'))])
    paper *= (0.94 + 0.06 * noise(rng, w, h, 3, 3, 2))[..., None]
    paper *= (0.8 + 0.2 * np.clip(radial(w, h, w / 2, h / 2, max(w, h) * 0.75) * 1.6, 0, 1))[..., None]
    marks = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(marks)
    for k in range(4):
        amp, freq, base, ph = rng.uniform(0.05, 0.14) * h, rng.uniform(1.5, 3.5), rng.uniform(0.3, 0.85) * h, rng.uniform(0, 6.3)
        pts = [(x, base + amp * math.sin(x / w * 6.28 * freq + ph)) for x in range(0, w + 4, 4)]
        d.line(pts, fill=200 - 30 * k, width=2 if k < 2 else 1)
    cx, cy, r = w * 0.78, h * 0.48, h * 0.3
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=230, width=3)
    d.ellipse((cx - r * 0.78, cy - r * 0.78, cx + r * 0.78, cy + r * 0.78), outline=180, width=1)
    for k in range(12):
        ang = 6.28 * k / 12
        d.line((cx + math.cos(ang) * r * 0.82, cy + math.sin(ang) * r * 0.82, cx + math.cos(ang) * r * 0.95,
                cy + math.sin(ang) * r * 0.95), fill=200, width=2)
    m = np.asarray(marks.filter(ImageFilter.GaussianBlur(0.6)), float)[..., None] / 255
    return mix(paper, ink, m * 0.85)


def blossom(w, h, pal, rng):
    out = vgrad(w, h, [(0, rgb('#12030f')), (0.6, rgb('#2a0820')), (1, rgb('#3c0c2c'))])
    moon, d = layer(w, h)
    cx, cy, r = w * 0.7, h * 0.4, h * 0.2
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=col(rgb('#ffe6f1')))
    out = light(out, moon, h * 0.2, 0.9)
    out += radial(w, h, cx, cy, h * 0.9)[..., None] ** 2 * pal[3] * 0.25
    branch, d = layer(w, h)
    flowers, e = layer(w, h)

    def grow(x, y, ang, length, width, depth):
        x2, y2 = x + math.cos(ang) * length, y + math.sin(ang) * length
        d.line((x, y, x2, y2), fill=(26, 6, 18), width=max(1, int(width)))
        if depth == 0 or length < 6:
            for _ in range(3):
                fx, fy, fr = x2 + rng.uniform(-6, 6), y2 + rng.uniform(-6, 6), rng.uniform(2, 3.5)
                for p in range(5):
                    a = 6.28 * p / 5
                    e.ellipse((fx + math.cos(a) * fr - fr, fy + math.sin(a) * fr - fr, fx + math.cos(a) * fr + fr,
                               fy + math.sin(a) * fr + fr), fill=col(mix(pal[3], WHITE, 0.08), rng.uniform(0.45, 0.8)))
            return
        for turn in (-0.4, 0.4):
            grow(x2, y2, ang + turn + rng.uniform(-0.2, 0.2), length * rng.uniform(0.6, 0.78), width * 0.65, depth - 1)

    # from the top right corner, across the moon and away from the clock on the left
    grow(w + 6, -4, math.pi * 0.82, h * 0.5, 6, 5)
    out = np.where(array(branch).max(axis=2)[..., None] > 0, array(branch), out)
    out = light(out, flowers, 2.5, 0.5, 0.75)
    petals, d = layer(w, h)
    for _ in range(w * h // 1400):
        x, y, a = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(0, 6.28)
        rx, ry = 2.6, 1.4
        d.polygon([(x + math.cos(a + t) * rx * math.cos(t) - math.sin(a) * ry * math.sin(t),
                    y + math.sin(a) * rx * math.cos(t) + math.cos(a) * ry * math.sin(t)) for t in np.linspace(0, 6.28, 10)],
                  fill=col(pal[3], rng.uniform(0.5, 0.95)))
    return light(out, petals, 1.2, 0.5)


def carbon(w, h, pal, rng):
    out = vgrad(w, h, [(0, rgb('#05080c')), (1, rgb('#0c1622'))])
    out += radial(w, h, w * 0.66, h * 0.5, h * 1.1)[..., None] ** 2 * rgb('#1c3a5c') * 0.5
    grid, d = layer(w, h)
    s = 9
    for row in range(-1, int(h / (s * 1.5)) + 2):
        for colm in range(-1, int(w / (s * 1.732)) + 2):
            cx = colm * s * 1.732 + (row % 2) * s * 0.866
            cy = row * s * 1.5
            pts = [(cx + s * math.cos(math.pi / 3 * k + math.pi / 6), cy + s * math.sin(math.pi / 3 * k + math.pi / 6))
                   for k in range(7)]
            d.line(pts, fill=(22, 40, 60), width=1)
    out = np.clip(out + array(grid) * 0.55, 0, 255)
    accent, d = layer(w, h)
    d.line((0, h - 3, w, h - 3), fill=(42, 74, 106), width=1)
    return light(out, accent, 2, 0.8)


def synthwave(w, h, pal, rng):
    pink, cyan, violet = pal[2], pal[1], pal[3]
    hz = 0.6
    out = vgrad(w, h, [(0, rgb('#0d0221')), (0.35, mix(violet, BLACK, 0.7)), (hz, mix(pink, BLACK, 0.25)), (hz + 0.001, rgb('#0d0221')),
                       (1, rgb('#14032e'))])
    sun = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(sun)
    cx, cy, r = w * 0.64, h * hz, h * 0.34
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    for k, band in enumerate(np.linspace(cy - r * 0.3, cy, 6)):
        d.rectangle((0, band, w, band + 1 + k * 0.6), fill=0)
    d.rectangle((0, cy, w, h), fill=0)
    m = np.asarray(sun, float)[..., None] / 255
    sun_col = vgrad(w, h, [(0, rgb('#ffd319')), (hz, pink), (1, pink)])
    out = mix(out, sun_col, m)
    out += radial(w, h, cx, cy, h * 0.75)[..., None] ** 2 * pink * 0.3
    grid, d = layer(w, h)
    y0 = h * hz
    for k in range(-16, 17):
        d.line((cx + k * w * 0.012, y0, cx + k * w * 0.16, h), fill=col(cyan, 0.7), width=1)
    yy, step = y0 + 2, 2.0
    while yy < h:
        d.line((0, yy, w, yy), fill=col(pink, 0.8), width=1)
        step *= 1.45
        yy += step
    return light(out, grid, 2.5, 0.9)


def toxic(w, h, pal, rng):
    out = vgrad(w, h, [(0, rgb('#020800')), (1, rgb('#0a1a02'))])
    for _ in range(3):
        out += radial(w, h, rng.uniform(0.2, 0.9) * w, rng.uniform(0.5, 1) * h, rng.uniform(0.25, 0.5) * h)[..., None] ** 2 * pal[2] * 0.4
    y = np.mgrid[0:h, 0:w][0]
    surface = ridge(rng, w, h * 0.68, h * 0.05, w / 10)
    goo = vgrad(w, h, [(0, mix(pal[1], BLACK, 0.4)), (1, mix(pal[1], BLACK, 0.8))])
    below = (y >= surface[None, :])
    out = np.where(below[..., None], goo, out)
    edge, d = layer(w, h)
    d.line([(x, surface[x]) for x in range(w)], fill=col(pal[0]), width=2)
    for _ in range(w // 18):
        x, yy, r = rng.uniform(0, w), rng.uniform(0.72, 0.98) * h, rng.uniform(1.5, 4)
        d.ellipse((x - r, yy - r, x + r, yy + r), outline=col(pal[4], 0.8), width=1)
    out = light(out, edge, 3, 1.0)
    stripes, d = layer(w, h)
    for x in range(-h, w + h, 14):
        d.polygon([(x, 0), (x + 7, 0), (x + 7 - 7, 7), (x - 7, 7)], fill=col(pal[4], 0.35))
    return np.clip(out + array(stripes), 0, 255)


def glow(w, h, pal, rng):
    out = vgrad(w, h, [(0, mix(pal[0], BLACK, 0.85)), (1, mix(pal[1 % len(pal)], BLACK, 0.7))])
    return out + radial(w, h, w * 0.6, h * 0.6, h)[..., None] ** 2 * pal[0] * 0.4


SCENES = {'ocean': ocean, 'aurora': aurora, 'city': city, 'dunes': dunes, 'deco': deco, 'fire': fire, 'rain': rain,
          'parchment': parchment, 'blossom': blossom, 'carbon': carbon, 'synthwave': synthwave, 'toxic': toxic}


# ---------------------------------------------------------------- the fan screens' emblems


def emblem(kind, d, c, s, i, rng):
    """Draw kind's emblem for fan i, centred in an s x s square, in colour c."""
    m, r = s / 2, s * 0.32
    rot = i * 0.4
    if kind in ('aurora',):
        for k in range(6):
            a = rot + math.pi / 3 * k
            x2, y2 = m + math.cos(a) * r, m + math.sin(a) * r
            d.line((m, m, x2, y2), fill=c, width=2)
            for f in (0.45, 0.7):
                bx, by = m + math.cos(a) * r * f, m + math.sin(a) * r * f
                for side in (-0.6, 0.6):
                    d.line((bx, by, bx + math.cos(a + side) * r * 0.28, by + math.sin(a + side) * r * 0.28), fill=c, width=1)
    elif kind == 'ocean':
        d.chord((m - r * 0.8, m - r * 0.9, m + r * 0.8, m + r * 0.5), 180, 360, fill=c)
        for k in range(5):
            x = m - r * 0.6 + k * r * 0.3
            d.line([(x + math.sin(t / 3 + k) * 2, m - r * 0.2 + t) for t in range(0, int(r * 1.2), 2)], fill=c, width=1)
    elif kind in ('dunes', 'deco'):
        spikes = 12 if kind == 'dunes' else 16
        d.ellipse((m - r * 0.45, m - r * 0.45, m + r * 0.45, m + r * 0.45), fill=c)
        for k in range(spikes):
            a = rot + 6.28 * k / spikes
            inner = r * 0.6
            outer = r * (1.05 if k % 2 == 0 or kind == 'dunes' else 0.8)
            d.line((m + math.cos(a) * inner, m + math.sin(a) * inner, m + math.cos(a) * outer, m + math.sin(a) * outer),
                   fill=c, width=2)
    elif kind == 'fire':
        flame = [(m - r * 0.55, m + r * 0.5), (m - r * 0.2, m - r * 0.2), (m, m - r * 1.05), (m + r * 0.25, m - r * 0.3),
                 (m + r * 0.55, m + r * 0.5), (m, m + r * 0.85)]
        d.polygon(flame, fill=c)
        d.polygon([(m - r * 0.25, m + r * 0.5), (m, m - r * 0.2), (m + r * 0.25, m + r * 0.5), (m, m + r * 0.7)], fill=(255, 220, 140))
    elif kind == 'rain':
        f = font(int(s * 0.16))
        for k in range(3):
            for j in range(5):
                d.text((m - r * 0.75 + k * r * 0.6, m - r + j * r * 0.42), str(int(rng.integers(10))), font=f,
                       fill=tuple(int(v * (1 - j * 0.15)) for v in c))
    elif kind == 'parchment':
        d.ellipse((m - r, m - r, m + r, m + r), outline=c, width=3)
        d.ellipse((m - r * 0.72, m - r * 0.72, m + r * 0.72, m + r * 0.72), outline=c, width=1)
        f = font(int(r * 1.0))
        d.text((m, m), 'L', font=f, fill=c, anchor='mm')
    elif kind == 'blossom':
        for p in range(5):
            a = rot + 6.28 * p / 5 - math.pi / 2
            px, py = m + math.cos(a) * r * 0.5, m + math.sin(a) * r * 0.5
            d.ellipse((px - r * 0.45, py - r * 0.45, px + r * 0.45, py + r * 0.45), fill=c)
        d.ellipse((m - r * 0.18, m - r * 0.18, m + r * 0.18, m + r * 0.18), fill=(255, 236, 180))
    elif kind == 'carbon':
        for scale, width in ((1.0, 2), (0.55, 1)):
            pts = [(m + r * scale * math.cos(math.pi / 3 * k + rot), m + r * scale * math.sin(math.pi / 3 * k + rot)) for k in range(7)]
            d.line(pts, fill=c, width=width)
    elif kind == 'synthwave':
        d.ellipse((m - r, m - r, m + r, m + r), fill=c)
        for k in range(4):
            yy = m + k * r * 0.24
            d.rectangle((m - r, yy, m + r, yy + 1 + k), fill=(13, 2, 33))
    elif kind == 'toxic':
        d.ellipse((m - r * 0.16, m - r * 0.16, m + r * 0.16, m + r * 0.16), fill=c)
        for k in range(3):
            a = rot + 6.28 * k / 3 - math.pi / 2
            d.pieslice((m - r, m - r, m + r, m + r), math.degrees(a) - 30, math.degrees(a) + 30, fill=c)
        d.ellipse((m - r * 0.28, m - r * 0.28, m + r * 0.28, m + r * 0.28), fill=(0, 0, 0))
        d.ellipse((m - r * 0.16, m - r * 0.16, m + r * 0.16, m + r * 0.16), fill=c)
    else:  # city and anything else: a circuit mark
        d.rectangle((m - r * 0.4, m - r * 0.4, m + r * 0.4, m + r * 0.4), outline=c, width=2)
        for k in range(4):
            a = rot + math.pi / 2 * k
            d.line((m + math.cos(a) * r * 0.4, m + math.sin(a) * r * 0.4, m + math.cos(a) * r, m + math.sin(a) * r), fill=c, width=2)
            d.ellipse((m + math.cos(a) * r - 2, m + math.sin(a) * r - 2, m + math.cos(a) * r + 2, m + math.sin(a) * r + 2), fill=c)


def fan(kind, i, pal, light_theme, rng):
    s = FAN
    c = pal[i % len(pal)]
    if light_theme:
        base = parchment(s, s, pal, rng)
        ink = mix(pal[0], BLACK, 0.6)
        mark, d = layer(s, s)
        emblem(kind, d, (255, 255, 255), s, i, rng)
        out = mix(base, ink, array(mark)[..., :1] / 255 * 0.9)
    else:
        out = np.zeros((s, s, 3)) + radial(s, s, s / 2, s / 2, s * 0.62)[..., None] ** 1.5 * mix(c, BLACK, 0.5)
        mark, d = layer(s, s)
        emblem(kind, d, col(mix(c, WHITE, 0.2) if c.max() > 60 else rgb('#2a4a6a')), s, i, rng)
        out = light(out, mark, 4, 0.9)
    ring = Image.new('L', (s, s), 0)
    ImageDraw.Draw(ring).ellipse((1, 1, s - 2, s - 2), fill=255)
    out = out * (np.asarray(ring.filter(ImageFilter.GaussianBlur(0.7)), float)[..., None] / 255)
    return image(out)


# ---------------------------------------------------------------- the screen templates' text


def write(base, pal, light_theme, items):
    """items: [(xy, text, size, anchor)]. Light text with a glow on dark scenes, ink on light ones."""
    w, h = base.shape[1], base.shape[0]
    # a soft shade behind the words, as a screen template keeps its text readable over any picture
    shade = Image.new('L', (w, h), 0)
    s = ImageDraw.Draw(shade)
    for xy, text, size, anchor in items:
        x1, y1, x2, y2 = s.textbbox(xy, text, font=font(size), anchor=anchor)
        s.rounded_rectangle((x1 - 12, y1 - 10, x2 + 12, y2 + 10), radius=10, fill=255)
    m = np.asarray(shade.filter(ImageFilter.GaussianBlur(14)), float)[..., None] / 255
    base = mix(base, rgb('#f2e7cf'), m * 0.45) if light_theme else base * (1 - m * 0.5)
    img = image(base)
    ink = tuple(int(v) for v in (mix(pal[0], BLACK, 0.68) if light_theme else mix(WHITE, pal[0], 0.18)))
    halo, d = layer(*img.size)
    for xy, text, size, anchor in items:
        d.text(xy, text, font=font(size), fill=col(mix(pal[0], WHITE, 0.1), 0.9), anchor=anchor)
    if not light_theme:
        img = ImageChops.screen(img, halo.filter(ImageFilter.GaussianBlur(5)))
    d = ImageDraw.Draw(img)
    for xy, text, size, anchor in items:
        d.text(xy, text, font=font(size), fill=ink, anchor=anchor)
    return img


def preview(theme):
    name = theme['name']
    pal = [rgb(c) for c in theme['swatch']] or [rgb('#808080')]
    while len(pal) < 6:
        pal.append(pal[len(pal) % max(1, len(pal))])
    kind = KIND.get(name, 'glow')
    light_theme = kind == 'parchment'
    seed = int(hashlib.sha256(name.encode()).hexdigest()[:8], 16)
    scene = SCENES.get(kind, glow)
    canvas = Image.new('RGB', (W, H), (5, 5, 5))
    for i in range(5):
        canvas.paste(fan(kind, i, pal, light_theme, np.random.default_rng(seed + i)), ((i * 96) + 1, 1))
    pump = scene(*PUMP, pal, np.random.default_rng(seed + 10))
    canvas.paste(write(pump, pal, light_theme, [((PUMP[0] - 12, 54), '33°', 30, 'rs'), ((PUMP[0] - 12, 70), 'COOLANT', 10, 'rs')]),
                 (482, 1))
    strip = scene(*STRIP, pal, np.random.default_rng(seed + 20))
    canvas.paste(write(strip, pal, light_theme, [((24, 84), '10:00', 64, 'ls'), ((27, 110), 'Thursday 24 September', 14, 'ls'),
                                                 ((STRIP[0] - 14, 70), '33°', 28, 'rs'), ((STRIP[0] - 14, 86), 'CPU', 10, 'rs'),
                                                 ((STRIP[0] - 14, 130), '39°', 28, 'rs'), ((STRIP[0] - 14, 146), 'GPU', 10, 'rs')]),
                 (0, 97))
    return canvas


def main():
    themes = json.loads((HERE.parent / 'themes.json').read_text())
    for theme in themes:
        target = HERE / Path(theme['preview']).name
        preview(theme).save(target, 'WEBP', quality=86, method=6)
        print(target.relative_to(HERE.parents[2]))


if __name__ == '__main__':
    main()
