#!/usr/bin/env python3
"""Draws the app icon in the CPC2027 look: the cream mist and the soft orange blob. Writes icon-1024.png and the AppIcon set.
Needs Pillow:  python3 mac/Icon/make_icon.py"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
here = os.path.dirname(os.path.abspath(__file__))
out_dir = os.path.join(here, "..", "App", "Assets.xcassets", "AppIcon.appiconset")

def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))

def radial(cx, cy, rx, ry, colour):
    """A soft radial wash of colour, as an RGBA layer."""
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    steps = 60
    for i in range(steps):
        t = i / steps
        a = int(255 * (1 - t) ** 1.6 / steps * 4)
        d.ellipse([cx - rx * (1 - t), cy - ry * (1 - t), cx + rx * (1 - t), cy + ry * (1 - t)], fill=None)
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    for i in range(steps, 0, -1):
        t = i / steps
        d.ellipse([cx - rx * t, cy - ry * t, cx + rx * t, cy + ry * t], fill=int(255 * (1 - t) ** 1.2))
    mask = mask.filter(ImageFilter.GaussianBlur(40))
    layer = Image.new("RGBA", (S, S), colour + (0,))
    layer.putalpha(mask)
    return layer

def gradient(size, c1, c2, c3=None, angle_vertical=True):
    w, h = size
    g = Image.new("RGB", (w, h))
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = (0.55 * x / w + 0.45 * y / h) if angle_vertical else (0.7 * (1 - x / w) + 0.3 * y / h)
            if c3 is None:
                c = [int(c1[k] + (c2[k] - c1[k]) * t) for k in range(3)]
            elif t < 0.55:
                u = t / 0.55; c = [int(c1[k] + (c2[k] - c1[k]) * u) for k in range(3)]
            else:
                u = (t - 0.55) / 0.45; c = [int(c2[k] + (c3[k] - c2[k]) * u) for k in range(3)]
            px[x, y] = tuple(c)
    return g

# Cream with mist: cool grey top left, peach on the right, sage bottom left.
icon = Image.new("RGBA", (S, S), hexrgb("#eeede9") + (255,))
icon = Image.alpha_composite(icon, radial(100, 0, 920, 560, hexrgb("#dde3e8")))
icon = Image.alpha_composite(icon, radial(1024, 560, 720, 460, hexrgb("#f3e3d6")))
icon = Image.alpha_composite(icon, radial(0, 1024, 920, 520, hexrgb("#e2e5db")))

# The blob: two soft shapes, blurred, as on the CPC start screen. Each is its gradient over the
# whole canvas with a blurred outline as alpha, so the soft edge keeps its colour.
def shape(box, colours, vertical, opacity, blur):
    x0, y0, x1, y1 = box
    g = Image.new("RGB", (S, S), colours[0])
    g.paste(gradient((x1 - x0, y1 - y0), *colours, angle_vertical=vertical), (x0, y0))
    g = g.filter(ImageFilter.GaussianBlur(blur))
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse(box, fill=int(255 * opacity))
    return Image.merge("RGBA", (*g.split(), m.filter(ImageFilter.GaussianBlur(blur))))

icon = Image.alpha_composite(icon, shape((270, 200, 790, 690), (hexrgb("#f4733f"), hexrgb("#f39a78"), hexrgb("#e8a9bd")), True, 1, 70))
icon = Image.alpha_composite(icon, shape((220, 430, 600, 790), (hexrgb("#c4a6d6"), hexrgb("#ef8a62")), False, 0.85, 70))

icon = icon.convert("RGB")
icon.save(os.path.join(here, "icon-1024.png"))
if "--preview" in sys.argv:
    sys.exit()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
print("Written the icon and the AppIcon set")
