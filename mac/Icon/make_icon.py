#!/usr/bin/env python3
"""Draws the app icon in the app's colours: a soft blob on mist, as on cpc2027, in the app's green.

  python3 mac/Icon/make_icon.py            the icon, positive: a green blob on cream
  python3 mac/Icon/make_icon.py --split    half negative (magenta on the orange mask), half positive

Writes icon-1024.png and every size in ../App/Assets.xcassets/AppIcon.appiconset. Needs Pillow.
Add --preview to write only icon-1024.png (or --out <file>)."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
here = os.path.dirname(os.path.abspath(__file__))
out_dir = os.path.join(here, "..", "App", "Assets.xcassets", "AppIcon.appiconset")

def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))

# The app's palettes (mac/App/Theme.swift): the positive, and the negative it develops from.
POSITIVE = dict(bg="#eeede9", mist=("#dde3e8", "#e2ebda", "#e2e5db"),
                blob_a=("#3fa866", "#86cc95", "#cde5a8"), blob_b=("#9ed2c6", "#5db574"))
NEGATIVE = dict(bg="#3b2216", mist=("#45291b", "#2c1f1c", "#3f2a17"),
                blob_a=("#c0477a", "#93405e", "#5e3a4c"), blob_b=("#6a3550", "#a9476d"))

def radial(cx, cy, rx, ry, colour):
    """A soft radial wash of colour, as an RGBA layer."""
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    steps = 60
    for i in range(steps, 0, -1):
        t = i / steps
        d.ellipse([cx - rx * t, cy - ry * t, cx + rx * t, cy + ry * t], fill=int(255 * (1 - t) ** 1.2))
    layer = Image.new("RGBA", (S, S), colour + (0,))
    layer.putalpha(mask.filter(ImageFilter.GaussianBlur(40)))
    return layer

def gradient(size, colours, vertical=True):
    w, h = size
    g = Image.new("RGB", (w, h))
    px = g.load()
    stops = [hexrgb(c) for c in colours]
    for y in range(h):
        for x in range(w):
            t = (0.55 * x / w + 0.45 * y / h) if vertical else (0.7 * (1 - x / w) + 0.3 * y / h)
            pos = t * (len(stops) - 1)
            i = min(int(pos), len(stops) - 2)
            u = pos - i
            px[x, y] = tuple(int(stops[i][k] + (stops[i + 1][k] - stops[i][k]) * u) for k in range(3))
    return g

def shape(box, colours, vertical, opacity, blur):
    """A soft shape: its gradient over the whole canvas with a blurred outline as alpha, so the
    soft edge keeps its colour."""
    x0, y0, x1, y1 = box
    g = Image.new("RGB", (S, S), hexrgb(colours[0]))
    g.paste(gradient((x1 - x0, y1 - y0), colours, vertical), (x0, y0))
    g = g.filter(ImageFilter.GaussianBlur(blur))
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse(box, fill=int(255 * opacity))
    return Image.merge("RGBA", (*g.split(), m.filter(ImageFilter.GaussianBlur(blur))))

def draw(p):
    icon = Image.new("RGBA", (S, S), hexrgb(p["bg"]) + (255,))
    icon = Image.alpha_composite(icon, radial(100, 0, 920, 560, hexrgb(p["mist"][0])))
    icon = Image.alpha_composite(icon, radial(1024, 560, 720, 460, hexrgb(p["mist"][1])))
    icon = Image.alpha_composite(icon, radial(0, 1024, 920, 520, hexrgb(p["mist"][2])))
    icon = Image.alpha_composite(icon, shape((270, 200, 790, 690), p["blob_a"], True, 1, 70))
    icon = Image.alpha_composite(icon, shape((220, 430, 600, 790), p["blob_b"], False, 0.85, 70))
    return icon.convert("RGB")

if "--split" in sys.argv:
    # The negative top left, the positive bottom right, meeting softly along the diagonal.
    soft = 90  # how wide the meeting is, in pixels
    mask = Image.new("L", (S, S))
    mask.putdata([max(0, min(255, int(((x + y) - S) / soft * 128 + 128))) for y in range(S) for x in range(S)])
    icon = Image.composite(draw(POSITIVE), draw(NEGATIVE), mask)
else:
    icon = draw(POSITIVE)

out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else os.path.join(here, "icon-1024.png")
icon.save(out)
if "--preview" in sys.argv or "--out" in sys.argv:
    sys.exit()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
print("Written the icon and the AppIcon set")
