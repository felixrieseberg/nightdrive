#!/usr/bin/env python3
"""Nightdrive alternate app icon — first-person night drive with dashboard.

Through-the-windshield view: dark dashboard silhouette with a glowing VFD
instrument cluster at the bottom, road with converging lane lines and
reflector posts vanishing into a horizon glow beyond the glass. Shipped as
Resources/AppIcon-1024-alt.png; the active icon (scripts/make-icon.py) is
the windshield-only variant, which reads better at small Dock sizes.

Cell-space pixel art (256x256), upscaled 8x NEAREST, then bloom, scanlines,
grain and vignette at working res, downsampled to 1024x1024 LANCZOS.
Requires Pillow.
"""

import math
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from icon_bezel import apply_monitor_treatment

CELLS = 256
SCALE = 8
FULL = CELLS * SCALE
OUT = 1024

random.seed(20031023)

OUT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon-1024-alt.png"
)

# ---------------------------------------------------------------- palette
BG_TOP = (5, 12, 11)
BG_HOR = (10, 24, 20)
BG_GROUND = (4, 9, 8)
DASH_DARK = (3, 7, 7)
DASH_LIT = (11, 26, 22)

MINT_HOT = (196, 255, 226)
MINT = (127, 239, 196)
MINT_MID = (74, 160, 129)
MINT_DIM = (36, 82, 66)
MINT_FAINT = (20, 46, 38)
AMBER_HOT = (255, 208, 132)
AMBER = (235, 166, 64)
AMBER_DIM = (120, 82, 32)
AMBER_FAINT = (58, 40, 17)

MINT_RAMP = [(6, 14, 12), MINT_FAINT, MINT_DIM, MINT_MID, MINT, MINT_HOT]
AMBER_RAMP = [(6, 14, 12), AMBER_FAINT, AMBER_DIM, AMBER, AMBER_HOT]

BAYER8 = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]


def bayer(x, y):
    return (BAYER8[y % 8][x % 8] + 0.5) / 64.0


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    t = clamp(t, 0.0, 1.0)
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def ramp_color(ramp, x, y, level):
    """`level` is a direct index into `ramp`; fractional parts are Bayer dithered."""
    level = clamp(level, 0.0, len(ramp) - 1.0)
    i = int(level)
    if i >= len(ramp) - 1:
        return ramp[-1]
    return ramp[i + 1] if bayer(x, y) < (level - i) else ramp[i]


# ---------------------------------------------------------------- geometry
VP_X, VP_Y = 128.0, 80.0          # vanishing point / horizon
ROAD_K = 1.60                     # road half-width per screen row below horizon
PERSP_H = 52.0                    # y = VP_Y + PERSP_H / z

GX, GY = 128.0, 194.0             # main gauge centre
G_OUT, G_IN = 50.0, 39.0
G_START, G_SWEEP, G_SEGS = 206.0, 232.0, 26
G_VALUE = 0.615
G_REDLINE = 0.80


def dash_top(x):
    """Screen row where the dashboard silhouette begins (hood humps at centre)."""
    u = (x - 128.0) / 128.0
    hump = 11.0 * math.exp(-((x - 128.0) / 66.0) ** 2)
    return 141.0 + 11.0 * u * u - hump


def road_half(y):
    return max(0.0, ROAD_K * (y - VP_Y))


img = Image.new("RGB", (CELLS, CELLS))
px = img.load()


def put(x, y, c):
    if 0 <= x < CELLS and 0 <= y < CELLS:
        px[x, y] = c


def blend(x, y, c, t):
    if 0 <= x < CELLS and 0 <= y < CELLS:
        px[x, y] = mix(px[x, y], c, t)


# ---------------------------------------------------------------- sky / glass
for y in range(CELLS):
    if y < VP_Y:
        t = (y / VP_Y) ** 1.7
        row = mix(BG_TOP, BG_HOR, t)
    else:
        row = BG_GROUND
    for x in range(CELLS):
        px[x, y] = row

# broad horizon glow beyond the vanishing point
for y in range(0, int(VP_Y) + 26):
    for x in range(CELLS):
        dx = (x - VP_X) / 92.0
        dy = (y - VP_Y) / 47.0
        g = math.exp(-(dx * dx + dy * dy) * 1.25)
        if g < 0.012:
            continue
        warm = math.exp(-(dx * dx * 5.0 + dy * dy * 3.0))
        col = mix(MINT_MID, AMBER, 0.52 * warm)
        blend(x, y, col, g * 0.70)

# tight bloom core right at the vanishing point
for y in range(int(VP_Y) - 16, int(VP_Y) + 10):
    for x in range(int(VP_X) - 22, int(VP_X) + 23):
        d = math.hypot((x - VP_X) / 13.0, (y - (VP_Y - 2)) / 7.0)
        g = math.exp(-d * d * 1.9)
        if g > 0.02:
            blend(x, y, MINT, g * 0.85)

# sparse stars
for _ in range(105):
    x = random.randrange(0, CELLS)
    y = random.randrange(6, int(VP_Y) - 20)
    if math.hypot((x - VP_X) / 70.0, (y - VP_Y) / 40.0) < 1.0:
        continue
    r = random.random()
    put(x, y, MINT_FAINT if r < 0.50 else (MINT_DIM if r < 0.86 else MINT_MID))

# ---------------------------------------------------------------- roadside
for y in range(int(VP_Y) + 1, CELLS):
    for x in range(CELLS):
        if y >= dash_top(x):
            continue
        half = road_half(y)
        if abs(x - VP_X) <= half:
            continue
        depth = clamp((y - VP_Y) / 52.0, 0.0, 1.0)
        blend(x, y, (7, 16, 14), 0.35 + 0.35 * (1.0 - depth))

# motion streaks on the verge
for _ in range(120):
    y = random.randint(int(VP_Y) + 4, 148)
    half = road_half(y)
    if half < 4:
        continue
    side = random.choice((-1, 1))
    off = half + random.uniform(2, 60)
    x0 = int(VP_X + side * off)
    ln = max(2, int(random.uniform(3, 16) * ((y - VP_Y) / 50.0)))
    if not (0 <= x0 < CELLS) or y >= dash_top(x0):
        continue
    for i in range(ln):
        xx = x0 + (i if side > 0 else -i)
        if 0 <= xx < CELLS and y < dash_top(xx):
            blend(xx, y, MINT_DIM, 0.30)

# ---------------------------------------------------------------- road surface
DASH_CENTRE = dash_top(128.0)

for y in range(int(VP_Y) + 1, CELLS):
    half = road_half(y)
    if half < 0.3:
        continue
    lo, hi = int(math.floor(VP_X - half)), int(math.ceil(VP_X + half))
    for x in range(max(0, lo), min(CELLS, hi + 1)):
        if y >= dash_top(x):
            continue
        u = (x - VP_X) / max(half, 0.5)
        blend(x, y, (9, 20, 17), 0.80)

        # headlight wash: two lobes, strongest on the near road
        near = clamp((y - VP_Y) / (DASH_CENTRE + 16 - VP_Y), 0.0, 1.0) ** 1.9
        lobes = math.exp(-((u - 0.44) / 0.34) ** 2) + math.exp(-((u + 0.44) / 0.34) ** 2)
        w = near * clamp(lobes, 0.0, 1.10) * 0.40
        if w > 0.01:
            put(x, y, ramp_color(MINT_RAMP, x, y, 0.75 + w * 7.8))

        # distance haze toward the horizon glow
        far = clamp(1.0 - (y - VP_Y) / 18.0, 0.0, 1.0)
        if far > 0.02:
            blend(x, y, MINT_MID, far * 0.50)

# lane edge lines
for y in range(int(VP_Y) + 1, CELLS):
    half = road_half(y)
    if half < 0.6:
        continue
    fade = clamp((y - VP_Y) / 48.0, 0.0, 1.0)
    width = 1 + (1 if fade > 0.30 else 0) + (1 if fade > 0.60 else 0) + (1 if fade > 0.86 else 0)
    for side in (-1, 1):
        base = VP_X + side * half
        for o in range(width):
            xx = int(round(base - side * o))
            if 0 <= xx < CELLS and y < dash_top(xx):
                put(xx, y, ramp_color(MINT_RAMP, xx, y, 3.05 + 2.6 * fade - 0.62 * o))

# centre dashes, perspective spaced, amber
z = 1.02
while z < 26.0:
    y_near = VP_Y + PERSP_H / z
    y_far = VP_Y + PERSP_H / (z + 0.44)
    if y_near - y_far < 0.85:
        break
    for y in range(int(round(y_far)), int(round(y_near)) + 1):
        if y <= VP_Y:
            continue
        half = road_half(y)
        w = half * 0.040
        fade = clamp((y - VP_Y) / 44.0, 0.0, 1.0)
        level = 2.15 + 1.85 * fade
        if w < 0.55:
            if y < dash_top(int(VP_X)):
                put(int(VP_X), y, ramp_color(AMBER_RAMP, int(VP_X), y, level - 0.5))
            continue
        lo, hi = int(round(VP_X - w)), int(round(VP_X + w))
        for x in range(lo, hi + 1):
            if y < dash_top(x):
                edge_soft = 0.7 if (x == lo or x == hi) else 0.0
                put(x, y, ramp_color(AMBER_RAMP, x, y, level - edge_soft))
    z *= 1.62

# reflector posts along the verge
for z in (1.35, 1.75, 2.35, 3.2, 4.5, 6.4, 9.2, 13.5, 20.0):
    y = VP_Y + PERSP_H / z
    half = road_half(y)
    scale = PERSP_H / z / PERSP_H
    for side in (-1, 1):
        bx = VP_X + side * (half + 7.0 * (54.0 / z) / 54.0 * 6.0)
        post_h = max(1.0, 26.0 / z)
        xi = int(round(bx))
        if not (0 <= xi < CELLS):
            continue
        for k in range(int(post_h)):
            yy = int(round(y - k))
            if yy <= VP_Y or yy >= dash_top(xi):
                continue
            put(xi, yy, MINT_FAINT if k < post_h * 0.62 else MINT_DIM)
        ty = int(round(y - post_h))
        if ty > VP_Y and ty < dash_top(xi):
            put(xi, ty, AMBER)
            if post_h > 5:
                put(xi, ty + 1, AMBER_DIM)
                put(xi + side, ty, AMBER_DIM)

# distant taillight pair in the right lane
for (tx, ty) in ((129, 84), (130, 84), (133, 84), (134, 84)):
    put(tx, ty, AMBER)
for (tx, ty) in ((129, 83), (130, 83), (133, 83), (134, 83), (131, 84), (132, 84)):
    blend(tx, ty, AMBER_DIM, 0.8)

# ---------------------------------------------------------------- dashboard
for x in range(CELLS):
    top = dash_top(x)
    ti = int(math.ceil(top))
    for y in range(ti, CELLS):
        depth = (y - top) / max(1.0, CELLS - top)
        base = mix(DASH_LIT, DASH_DARK, clamp(depth * 2.4, 0.0, 1.0))
        px[x, y] = base

# cluster light spilling onto the dash face
for y in range(int(dash_top(128.0)) - 2, CELLS):
    for x in range(CELLS):
        if y < dash_top(x):
            continue
        d = math.hypot((x - GX) / 105.0, (y - GY) / 74.0)
        g = math.exp(-d * d * 2.3) * 0.5
        if g > 0.015:
            blend(x, y, MINT_DIM, g)

# rim highlight along the top of the dash, plus spill onto the glass above
for x in range(CELLS):
    top = dash_top(x)
    ti = int(math.ceil(top))
    edge = 1.0 - abs(x - 128.0) / 150.0
    put(x, ti, ramp_color(MINT_RAMP, x, ti, 1.8 + 2.05 * edge))
    if ti + 1 < CELLS:
        blend(x, ti + 1, MINT_DIM, 0.55)
    for k in range(1, 13):
        yy = ti - k
        if yy <= VP_Y:
            break
        blend(x, yy, MINT_MID, 0.30 * edge * math.exp(-(k / 5.0) ** 2))

# ---------------------------------------------------------------- gauges
def draw_gauge(cx, cy, r_out, r_in, start, sweep, nseg, value, dim=0.0,
               redline=G_REDLINE, needle_len=None, hub=True):
    lo_x, hi_x = int(cx - r_out - 6), int(cx + r_out + 7)
    lo_y, hi_y = int(cy - r_out - 6), int(cy + r_out + 7)
    seg_span = sweep / nseg
    for y in range(max(0, lo_y), min(CELLS, hi_y)):
        for x in range(max(0, lo_x), min(CELLS, hi_x)):
            dx, dy = x - cx, cy - y
            d = math.hypot(dx, dy)
            if d > r_out + 4.5 or d < r_in - 5.0:
                continue
            a = math.degrees(math.atan2(dy, dx))
            if a < -100.0:
                a += 360.0
            rel = start - a
            if rel < -1.0 or rel > sweep + 1.0:
                continue

            # outer hairline arc
            if r_out + 2.2 <= d <= r_out + 3.4:
                if int(rel) % 3 != 0:
                    put(x, y, mix(MINT_FAINT, MINT_DIM, 0.5 - dim * 0.4))
                continue
            # inner hairline arc
            if r_in - 3.6 <= d <= r_in - 2.6:
                put(x, y, mix((7, 17, 14), MINT_FAINT, 1.0 - dim))
                continue
            if not (r_in <= d <= r_out):
                continue

            i = int(clamp(rel / seg_span, 0, nseg - 1e-6))
            local = (rel - i * seg_span) / seg_span
            if local < 0.16 or local > 0.90:
                continue

            f = (i + 0.5) / nseg
            radial = (d - r_in) / max(1.0, r_out - r_in)
            if f > redline:
                lit = f <= value
                lum = (3.95 if lit else 1.9) - 0.3 * abs(radial - 0.5)
                put(x, y, ramp_color(AMBER_RAMP, x, y, lum - dim * 1.1))
            elif f <= value:
                lum = 3.05 + 2.25 * (f / max(value, 0.01)) ** 1.3
                lum -= 0.26 * abs(radial - 0.5) * 2.0
                put(x, y, ramp_color(MINT_RAMP, x, y, lum - dim * 1.5))
            else:
                put(x, y, ramp_color(MINT_RAMP, x, y, 1.8 - dim * 0.75))

    if needle_len is None:
        return
    ang = math.radians(start - sweep * value)
    nx, ny = math.cos(ang), -math.sin(ang)
    span = int(needle_len) + 12
    for y in range(max(0, int(cy - span)), min(CELLS, int(cy + span))):
        for x in range(max(0, int(cx - span)), min(CELLS, int(cx + span))):
            vx, vy = x - cx, y - cy
            proj = vx * nx + vy * ny
            perp = abs(-vx * ny + vy * nx)
            if 2.0 <= proj <= needle_len:
                t = (proj - 2.0) / max(1.0, needle_len - 2.0)
                hw = lerp(2.5, 0.65, t)
                if perp <= hw:
                    put(x, y, ramp_color(AMBER_RAMP, x, y, 4.0 - 0.35 * t))
                elif perp <= hw + 1.0:
                    put(x, y, ramp_color(AMBER_RAMP, x, y, 2.35))
            elif -9.0 <= proj <= -2.5 and perp <= 1.5:
                put(x, y, AMBER_DIM)

    if hub:
        for y in range(int(cy - 7), int(cy + 8)):
            for x in range(int(cx - 7), int(cx + 8)):
                d = math.hypot(x - cx, y - cy)
                if d <= 3.2:
                    put(x, y, ramp_color(MINT_RAMP, x, y, 5.0))
                elif d <= 5.0:
                    put(x, y, ramp_color(MINT_RAMP, x, y, 3.0))
                elif d <= 6.2:
                    put(x, y, ramp_color(MINT_RAMP, x, y, 1.6))


# darken the gauge face so the segments read
for y in range(int(GY - G_OUT - 8), int(GY + G_OUT + 9)):
    for x in range(int(GX - G_OUT - 8), int(GX + G_OUT + 9)):
        d = math.hypot(x - GX, y - GY)
        if d <= G_OUT + 5.5 and 0 <= x < CELLS and 0 <= y < CELLS and y >= dash_top(x) - 3:
            blend(x, y, (3, 8, 7), 0.88)

draw_gauge(GX, GY, G_OUT, G_IN, G_START, G_SWEEP, G_SEGS, G_VALUE, needle_len=34.0)

# flanking mini gauges
draw_gauge(34.0, 206.0, 25.0, 18.5, 200.0, 220.0, 13, 0.42, dim=0.9,
           redline=0.84, needle_len=None, hub=False)
draw_gauge(222.0, 206.0, 25.0, 18.5, 200.0, 220.0, 13, 0.74, dim=0.9,
           redline=0.84, needle_len=None, hub=False)

# tiny spectrum readout inside the gauge, below the hub
SP_BASE = 219
SP_BARS = 11
SP_W, SP_GAP = 3, 2
sp_total = SP_BARS * SP_W + (SP_BARS - 1) * SP_GAP
sp_x0 = int(GX - sp_total / 2)
sp_heights = [4, 7, 12, 9, 15, 11, 17, 8, 13, 6, 3]
for i, h in enumerate(sp_heights):
    bx = sp_x0 + i * (SP_W + SP_GAP)
    for k in range(h):
        yy = SP_BASE - k
        lvl = k / max(1, h - 1)
        for x in range(bx, bx + SP_W):
            if k == h - 1 and h > 10:
                put(x, yy, ramp_color(AMBER_RAMP, x, yy, 3.6))
            else:
                put(x, yy, ramp_color(MINT_RAMP, x, yy, 2.4 + 2.0 * (1.0 - lvl)))
    for x in range(bx, bx + SP_W):
        put(x, SP_BASE + 1, MINT_DIM)

# steering wheel rim arc across the very bottom of the dash
WHEEL_CX, WHEEL_CY, WHEEL_R = 128.0, 362.0, 120.0
for y in range(238, CELLS):
    for x in range(CELLS):
        d = math.hypot(x - WHEEL_CX, y - WHEEL_CY)
        if d > WHEEL_R:
            continue
        crown = clamp(1.0 - abs(x - WHEEL_CX) / 150.0, 0.0, 1.0)
        if d > WHEEL_R - 2.0:
            put(x, y, ramp_color(MINT_RAMP, x, y, 1.15 + 1.35 * crown))
        elif d > WHEEL_R - 13.0:
            px[x, y] = mix((5, 12, 10), (2, 5, 5), (WHEEL_R - d) / 13.0)
        else:
            px[x, y] = (2, 5, 5)


# ---------------------------------------------------------------- upscale + fx
big = img.resize((FULL, FULL), Image.NEAREST)


def bright_pass(im, threshold=104):
    step = 2
    small = im.resize((im.size[0] // step, im.size[1] // step), Image.BILINEAR)
    sp = small.load()
    o = Image.new("RGB", small.size, (0, 0, 0))
    op = o.load()
    for y in range(small.size[1]):
        for x in range(small.size[0]):
            r, g, b = sp[x, y]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum > threshold:
                k = min(1.0, (lum - threshold) / 88.0)
                op[x, y] = (int(r * k), int(g * k), int(b * k))
    return o.resize(im.size, Image.BILINEAR)


bp = bright_pass(big)
glow1 = bp.filter(ImageFilter.GaussianBlur(FULL * 0.0055))
glow2 = bp.filter(ImageFilter.GaussianBlur(FULL * 0.022))
big = ImageChops.screen(big, glow1)
big = ImageChops.screen(
    big, ImageChops.multiply(glow2, Image.new("RGB", big.size, (172, 172, 172)))
)

# scanlines
sl = Image.new("L", (1, FULL))
slp = sl.load()
for y in range(FULL):
    slp[0, y] = 231 if (y // 4) % 2 else 255
sl = sl.resize((FULL, FULL))
big = ImageChops.multiply(big, Image.merge("RGB", (sl, sl, sl)))

# grain
noise = Image.effect_noise((FULL, FULL), 14).convert("L")
noise_rgb = Image.merge("RGB", (noise, noise, noise))
big = Image.blend(big, ImageChops.overlay(big, noise_rgb), 0.20)

# vignette
vig = Image.new("L", (FULL, FULL), 0)
vd = ImageDraw.Draw(vig)
vd.ellipse((-FULL * 0.26, -FULL * 0.30, FULL * 1.26, FULL * 1.30), fill=255)
vig = vig.filter(ImageFilter.GaussianBlur(FULL * 0.115))
black = Image.new("RGB", (FULL, FULL), (2, 5, 4))
big = Image.composite(big, black, vig)

final = big.resize((OUT, OUT), Image.LANCZOS)

# Frame the scene as a lit display so the icon reads as an object in the Dock.
final = apply_monitor_treatment(final)

final.save(OUT_PATH)
print("wrote", OUT_PATH)
