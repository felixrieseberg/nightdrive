#!/usr/bin/env python3
"""Nightdrive app icon source — windshield night drive.

No dashboard, no instrument cluster. Just the night: sky, a hot horizon
glow at the vanishing point, and a road filling the lower frame with
converging mint lane lines, amber centre dashes and amber reflector posts.
Composed for legibility down to 32px.

Cell-space pixel art (256x256), upscaled 8x NEAREST, then bloom, scanlines,
grain and vignette at working res, downsampled to 1024x1024 LANCZOS.

Regenerates Resources/AppIcon-1024.png (the committed icon source used by
scripts/build-app.sh and `make icon`). Requires Pillow: run with a Python
that has it installed, e.g. `python3 -m pip install --user pillow`.
See scripts/make-icon-alt.py for the alternate dashboard-cluster artwork.
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


OUT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon-1024.png"
)

# ---------------------------------------------------------------- palette
BG_TOP = (5, 12, 11)
BG_HOR = (10, 24, 20)
BG_GROUND = (4, 9, 8)

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


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    t = clamp(t, 0.0, 1.0)
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def ramp_color(ramp, x, y, level):
    """`level` is a direct index into `ramp`; fractional parts are Bayer dithered."""
    level = clamp(level, 0.0, len(ramp) - 1.0)
    i = int(level)
    if i >= len(ramp) - 1:
        return ramp[-1]
    return ramp[i + 1] if bayer(x, y) < (level - i) else ramp[i]


# ---------------------------------------------------------------- geometry
# Horizon on the golden cut: the screen art is inset by 8.4% per side in the
# final bezel composite, so cell 165 lands at 1/phi (61.8%) of the full icon:
# 0.084 + (165/256) * 0.832 = 0.620
VP_X, VP_Y = 128.0, 165.0
ROAD_K = 1.45                 # road half-width per row below the horizon
PERSP_H = 104.0               # y = VP_Y + PERSP_H / z


def road_half(y):
    return max(0.0, ROAD_K * (y - VP_Y))


def render_icon(phase=0.0):
    """Render the full 1024px icon. `phase` in [0,1) advances the dashes
    and reflector posts one spacing step toward the viewer; the pattern is
    geometric in z, so phase 1.0 maps onto phase 0.0 for a seamless loop."""
    random.seed(19790914)
    img = Image.new("RGB", (CELLS, CELLS))
    px = img.load()


    def put(x, y, c):
        if 0 <= x < CELLS and 0 <= y < CELLS:
            px[x, y] = c


    def blend(x, y, c, t):
        if 0 <= x < CELLS and 0 <= y < CELLS:
            px[x, y] = mix(px[x, y], c, t)


    # ---------------------------------------------------------------- sky
    for y in range(CELLS):
        if y < VP_Y:
            t = (y / VP_Y) ** 1.55
            row = mix(BG_TOP, BG_HOR, t)
        else:
            row = BG_GROUND
        for x in range(CELLS):
            px[x, y] = row

    # wide horizon glow
    for y in range(0, CELLS):
        for x in range(CELLS):
            dx = (x - VP_X) / 112.0
            dy = (y - VP_Y) / 76.0
            g = math.exp(-(dx * dx + dy * dy) * 1.15)
            if g < 0.012:
                continue
            warm = math.exp(-(dx * dx * 4.2 + dy * dy * 2.6))
            col = mix(MINT_MID, AMBER, 0.50 * warm)
            blend(x, y, col, g * 0.86)

    # hot core at the vanishing point
    for y in range(int(VP_Y) - 30, int(VP_Y) + 18):
        for x in range(int(VP_X) - 40, int(VP_X) + 41):
            d = math.hypot((x - VP_X) / 20.0, (y - (VP_Y - 4)) / 10.0)
            g = math.exp(-d * d * 1.6)
            if g > 0.015:
                blend(x, y, MINT, g * 0.95)
            d2 = math.hypot((x - VP_X) / 9.0, (y - (VP_Y - 4)) / 5.0)
            g2 = math.exp(-d2 * d2 * 2.0)
            if g2 > 0.03:
                blend(x, y, MINT_HOT, g2 * 0.90)

    # stars
    for _ in range(210):
        x = random.randrange(0, CELLS)
        y = random.randrange(3, int(VP_Y) - 22)
        if math.hypot((x - VP_X) / 92.0, (y - VP_Y) / 52.0) < 1.0 and random.random() < 0.7:
            continue
        r = random.random()
        put(x, y, MINT_FAINT if r < 0.46 else (MINT_DIM if r < 0.84 else MINT_MID))
        if r > 0.975:
            put(x, y, MINT)

    # ---------------------------------------------------------------- ground
    for y in range(int(VP_Y), CELLS):
        for x in range(CELLS):
            depth = clamp((y - VP_Y) / 60.0, 0.0, 1.0)
            blend(x, y, (6, 14, 12), 0.30 + 0.45 * (1.0 - depth))

    # horizon line: a thin bright rule that anchors the composition
    HY = int(VP_Y)
    for x in range(CELLS):
        edge = clamp(1.0 - abs(x - VP_X) / 132.0, 0.0, 1.0) ** 0.62
        lvl = 4.95 * edge
        if lvl > 1.85:
            put(x, HY, ramp_color(MINT_RAMP, x, HY, lvl))
        if lvl > 2.60:
            put(x, HY + 1, ramp_color(MINT_RAMP, x, HY + 1, lvl - 1.5))
        if lvl > 3.80:
            put(x, HY - 1, ramp_color(MINT_RAMP, x, HY - 1, lvl - 2.2))

    # motion streaks along the verge
    for _ in range(150):
        y = random.randint(int(VP_Y) + 3, CELLS - 1)
        half = road_half(y)
        side = random.choice((-1, 1))
        x0 = int(VP_X + side * (half + random.uniform(3, 90)))
        if not (0 <= x0 < CELLS):
            continue
        ln = max(2, int(random.uniform(4, 22) * ((y - VP_Y) / 70.0)))
        for i in range(ln):
            xx = x0 + (i if side > 0 else -i)
            blend(xx, y, MINT_DIM, 0.32)

    # ---------------------------------------------------------------- road
    for y in range(int(VP_Y) + 1, CELLS):
        half = road_half(y)
        if half < 0.3:
            continue
        lo, hi = int(math.floor(VP_X - half)), int(math.ceil(VP_X + half))
        for x in range(max(0, lo), min(CELLS, hi + 1)):
            u = (x - VP_X) / max(half, 0.5)
            blend(x, y, (9, 20, 17), 0.82)

            near = clamp((y - VP_Y) / (CELLS - VP_Y), 0.0, 1.0) ** 1.3
            lobes = math.exp(-((u - 0.40) / 0.46) ** 2) + math.exp(-((u + 0.40) / 0.46) ** 2)
            w = near * clamp(lobes, 0.0, 1.05) * 0.34
            if w > 0.005:
                blend(x, y, MINT_MID, clamp(w * 1.9, 0.0, 0.80))
            if w > 0.13 + 0.07 * bayer(x, y):
                put(x, y, ramp_color(MINT_RAMP, x, y, 1.85 + (w - 0.13) * 9.0))

            far = clamp(1.0 - (y - VP_Y) / 26.0, 0.0, 1.0)
            if far > 0.02:
                blend(x, y, MINT_MID, far * 0.55)

    # lane edge lines
    for y in range(int(VP_Y) + 1, CELLS):
        half = road_half(y)
        if half < 0.6:
            continue
        fade = clamp((y - VP_Y) / (CELLS - VP_Y), 0.0, 1.0)
        width = 1 + int(fade * 6.0)
        for side in (-1, 1):
            base = VP_X + side * half
            for o in range(width):
                xx = int(round(base - side * o))
                put(xx, y, ramp_color(MINT_RAMP, xx, y, 3.5 + 2.4 * fade - 0.5 * o))

    # centre dashes, perspective spaced, amber; `phase` slides them toward
    # the viewer by one geometric spacing step per cycle
    z = 1.18 * (1.58 ** -phase)
    while z < 22.0:
        y_near = VP_Y + PERSP_H / z
        y_far = VP_Y + PERSP_H / (z + 0.46)
        if y_near - y_far < 0.85:
            break
        for y in range(int(round(y_far)), int(round(y_near)) + 1):
            if y <= VP_Y or y >= CELLS:
                continue
            half = road_half(y)
            w = half * 0.045
            fade = clamp((y - VP_Y) / 78.0, 0.0, 1.0)
            level = 2.35 + 1.65 * fade
            if w < 0.55:
                put(int(VP_X), y, ramp_color(AMBER_RAMP, int(VP_X), y, level - 0.45))
                continue
            lo, hi = int(round(VP_X - w)), int(round(VP_X + w))
            for x in range(lo, hi + 1):
                soft = 0.65 if (x == lo or x == hi) else 0.0
                put(x, y, ramp_color(AMBER_RAMP, x, y, level - soft))
        z *= 1.58

    # reflector posts along the verge, geometric in z so the march loops
    for k in range(10):
        z = 1.05 * (1.44 ** (k - phase))
        if z > 23.0:
            continue
        y = VP_Y + PERSP_H / z
        if y >= CELLS + 12:
            continue
        half = road_half(y)
        for side in (-1, 1):
            bx = VP_X + side * (half + 62.0 / z)
            xi = int(round(bx))
            if not (0 <= xi < CELLS):
                continue
            post_h = max(1.0, 40.0 / z)
            thick = 1 if post_h < 14 else 2
            for k in range(int(post_h)):
                yy = int(round(y - k))
                if yy <= VP_Y or yy >= CELLS:
                    continue
                for t in range(thick):
                    put(xi + (t if side > 0 else -t), yy,
                        MINT_FAINT if k < post_h * 0.6 else MINT_DIM)
            ty = int(round(y - post_h))
            if VP_Y < ty < CELLS:
                for t in range(thick):
                    put(xi + (t if side > 0 else -t), ty, AMBER)
                if post_h > 6:
                    for t in range(thick):
                        put(xi + (t if side > 0 else -t), ty + 1, AMBER_HOT)
                        put(xi + (t if side > 0 else -t), ty - 1, AMBER_DIM)

    # ---------------------------------------------------------------- upscale + fx
    big = img.resize((FULL, FULL), Image.NEAREST)


    def bright_pass(im, threshold=100):
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
                    k = min(1.0, (lum - threshold) / 85.0)
                    op[x, y] = (int(r * k), int(g * k), int(b * k))
        return o.resize(im.size, Image.BILINEAR)


    bp = bright_pass(big)
    glow1 = bp.filter(ImageFilter.GaussianBlur(FULL * 0.006))
    glow2 = bp.filter(ImageFilter.GaussianBlur(FULL * 0.024))
    big = ImageChops.screen(big, glow1)
    big = ImageChops.screen(
        big, ImageChops.multiply(glow2, Image.new("RGB", big.size, (180, 180, 180)))
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
    return final


def apply_dock_mask(image):
    """Clip a frame to the Dock tile squircle.

    macOS masks the bundle's static icon into a rounded-rect tile
    automatically, but images set via `NSApp.applicationIconImage` are shown
    raw — so animation frames carry the tile shape in their alpha channel.
    Radius matches Apple's icon-grid corner proportion (~22.5% of the edge).
    """
    size = image.size[0]
    supersample = 4
    s = size * supersample
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=int(s * 0.225), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def _render_frame(job):
    index, count, size, out_dir = job
    frame = render_icon(phase=index / count).resize((size, size), Image.LANCZOS)
    frame = apply_dock_mask(frame)
    path = os.path.join(out_dir, "frame_%02d.png" % index)
    frame.save(path)
    return path


def main():
    import argparse
    import multiprocessing

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--frames",
        type=int,
        metavar="N",
        help="render an N-frame seamless animation loop instead of the static icon",
    )
    parser.add_argument(
        "--size", type=int, default=256, help="frame edge size in px (default 256)"
    )
    parser.add_argument(
        "--out",
        help="output directory for --frames (default Sources/Nightdrive/Resources/DockIconFrames)",
    )
    args = parser.parse_args()

    if args.frames:
        out_dir = args.out or os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..",
            "Sources",
            "Nightdrive",
            "Resources",
            "DockIconFrames",
        )
        os.makedirs(out_dir, exist_ok=True)
        jobs = [(i, args.frames, args.size, out_dir) for i in range(args.frames)]
        with multiprocessing.Pool() as pool:
            for path in pool.imap(_render_frame, jobs):
                print("wrote", path)
    else:
        render_icon().save(OUT_PATH)
        print("wrote", OUT_PATH)


if __name__ == "__main__":
    main()
