"""Shared Dock "monitor" treatment for Nightdrive icon generators.

macOS Dock icons read as lit objects. `apply_monitor_treatment` frames a
square scene like a display, in the Ghostty vein: a bright metallic outer
bezel, a dark inner bezel, then the scene inset as the glowing screen.
Geometry follows the standard squircle mask the system (or packaging)
applies later.
"""

import math

from PIL import Image, ImageChops, ImageDraw, ImageFilter


def squircle_mask(size, inset=0.0, n=5.0, supersample=4):
    s = size * supersample
    half = s / 2.0
    a = half - inset * supersample
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    pts = []
    steps = 720
    for i in range(steps):
        ang = 2 * math.pi * i / steps
        c, sn = math.cos(ang), math.sin(ang)
        x = half + a * math.copysign(abs(c) ** (2.0 / n), c)
        y = half + a * math.copysign(abs(sn) ** (2.0 / n), sn)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def apply_monitor_treatment(scene):
    out = scene.size[0]

    # exposure lift: gentle midtone brightening so the screen doesn't sit back
    lifted = scene.point(lambda v: int(255 * ((v / 255) ** 0.90)))
    scene = Image.blend(scene, lifted, 0.7)

    bezel_w = int(out * 0.058)      # bright outer bezel width
    inner_w = int(out * 0.026)      # dark inner bezel width
    screen_inset = bezel_w + inner_w

    # bright metallic bezel: vertical brushed gradient, brighter on top,
    # tinted faintly toward the phosphor mint
    bezel = Image.new("RGB", (out, out))
    bz = bezel.load()
    for y in range(out):
        t = y / out
        v = 208 - int(96 * t)
        row = (int(v * 0.92), v, int(v * 0.97))
        for x in range(out):
            bz[x, y] = row
    # subtle horizontal sheen so the metal doesn't look flat
    sheen = Image.new("L", (out, 1))
    sh = sheen.load()
    for x in range(out):
        sh[x, 0] = int(20 * math.sin(math.pi * x / out) ** 2)
    bezel = ImageChops.screen(bezel, Image.merge("RGB", (sheen.resize((out, out)),) * 3))

    # dark inner bezel: near-black hardware gap around the screen
    inner_bezel = Image.new("RGB", (out, out), (14, 20, 18))

    # screen: scene scaled down into the inner window
    screen_size = out - 2 * screen_inset
    screen_art = scene.resize((screen_size, screen_size), Image.LANCZOS)

    # assemble back-to-front
    final = bezel
    inner_mask = squircle_mask(out, inset=bezel_w)
    final = Image.composite(inner_bezel, final, inner_mask)
    screen_layer = Image.new("RGB", (out, out), (0, 0, 0))
    screen_layer.paste(screen_art, (screen_inset, screen_inset))
    screen_mask = squircle_mask(out, inset=screen_inset)
    final = Image.composite(screen_layer, final, screen_mask)

    # screen glow spilling onto the dark inner bezel
    spill_src = Image.new("RGB", (out, out), (0, 0, 0))
    spill_src.paste(screen_art, (screen_inset, screen_inset))
    spill = spill_src.filter(ImageFilter.GaussianBlur(out * 0.012))
    gap_mask = ImageChops.subtract(inner_mask, screen_mask)
    final = Image.composite(ImageChops.screen(final, spill), final, gap_mask)

    # bezel edge shading: dark seam where the bezel meets the inner well,
    # and a bright top specular on the bezel's outer edge
    seam = ImageChops.subtract(
        squircle_mask(out, inset=bezel_w - int(out * 0.006)), inner_mask
    )
    final = Image.composite(final.point(lambda v: v * 132 // 255), final, seam)

    edge_hl = ImageChops.subtract(
        squircle_mask(out, inset=int(out * 0.004)),
        squircle_mask(out, inset=int(out * 0.014)),
    )
    hl_grad = Image.new("L", (1, out))
    hg = hl_grad.load()
    for y in range(out):
        hg[0, y] = int(200 * (1.0 - y / out) ** 1.2 + 30)
    edge_hl = ImageChops.multiply(edge_hl, hl_grad.resize((out, out)))
    edge_hl = edge_hl.filter(ImageFilter.GaussianBlur(out * 0.002))
    final = ImageChops.screen(final, Image.merge("RGB", (edge_hl,) * 3))

    return final
