#!/usr/bin/env python3
"""Generate ThermalBar app icon: macOS-style rounded square, cool-to-hot
gradient, white thermometer glyph. Outputs AppIcon.iconset/*.png."""
import math
import os
from PIL import Image, ImageDraw

SS = 8          # supersampling factor
BASE = 1024     # final canvas

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def rounded_rect_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

def render_master():
    S = BASE * SS
    img = Image.new("RGB", (S, S))
    # vertical gradient: deep blue (cool) -> orange-red (hot)
    top = (32, 84, 180)
    mid = (170, 90, 140)
    bot = (224, 62, 40)
    px = img.load()
    for y in range(S):
        t = y / (S - 1)
        c = lerp(top, mid, t * 2) if t < 0.5 else lerp(mid, bot, t * 2 - 1)
        for x in range(S):
            px[x, y] = c
    # subtle radial highlight top-left
    hl = Image.new("L", (S, S), 0)
    hd = ImageDraw.Draw(hl)
    hd.ellipse([-S * 0.35, -S * 0.45, S * 0.75, S * 0.55], fill=60)
    hl = hl.resize((S // 2, S // 2)).resize((S, S))  # cheap blur
    white = Image.new("RGB", (S, S), (255, 255, 255))
    img = Image.composite(white, img, hl.point(lambda v: v // 3))

    # macOS squircle-ish mask
    mask = rounded_rect_mask(S, int(S * 0.225))
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(img, (0, 0), mask)

    # thermometer glyph
    d = ImageDraw.Draw(icon)
    cx = S * 0.5
    tube_w = S * 0.085
    tube_top = S * 0.16
    tube_bot = S * 0.60
    bulb_r = S * 0.145
    bulb_cy = S * 0.70
    white_c = (255, 255, 255, 255)

    # outer tube (white)
    d.rounded_rectangle(
        [cx - tube_w, tube_top, cx + tube_w, bulb_cy],
        radius=tube_w, fill=white_c)
    d.ellipse([cx - bulb_r, bulb_cy - bulb_r, cx + bulb_r, bulb_cy + bulb_r],
              fill=white_c)

    # inner cutout (gradient-colored): use bottom color for "mercury-free" channel
    inner_w = tube_w * 0.45
    inner_r = bulb_r * 0.55
    cut = lerp(top, bot, 0.35) + (255,)
    d.rounded_rectangle(
        [cx - inner_w, tube_top + tube_w * 0.9, cx + inner_w, bulb_cy],
        radius=inner_w, fill=cut)
    d.ellipse([cx - inner_r, bulb_cy - inner_r, cx + inner_r, bulb_cy + inner_r],
              fill=cut)

    # mercury: fill inner channel up to ~55% with hot color
    merc = (255, 92, 60, 255)
    m_top = tube_top + (bulb_cy - tube_top) * 0.55
    d.rounded_rectangle([cx - inner_w, m_top, cx + inner_w, bulb_cy],
                        radius=inner_w, fill=merc)
    d.ellipse([cx - inner_r, bulb_cy - inner_r, cx + inner_r, bulb_cy + inner_r],
              fill=merc)

    # tick marks on the right of tube
    for i, frac in enumerate([0.22, 0.32, 0.42]):
        y = tube_top + (bulb_cy - tube_top) * frac + tube_w * 0.5
        x0 = cx + tube_w * 1.35
        x1 = cx + tube_w * (2.1 if i == 1 else 1.8)
        d.rounded_rectangle([x0, y - S * 0.008, x1, y + S * 0.008],
                            radius=S * 0.008, fill=white_c)

    return icon.resize((BASE, BASE), Image.LANCZOS)

def main():
    out = "Resources/AppIcon.iconset"
    os.makedirs(out, exist_ok=True)
    master = render_master()
    master.save("Resources/AppIcon-1024.png")
    for size in (16, 32, 64, 128, 256, 512):
        im = master.resize((size, size), Image.LANCZOS)
        im.save(f"{out}/icon_{size}x{size}.png")
        if size <= 512:
            im2 = master.resize((size * 2, size * 2), Image.LANCZOS)
            im2.save(f"{out}/icon_{size}x{size}@2x.png")
    print("iconset written to", out)

if __name__ == "__main__":
    main()
