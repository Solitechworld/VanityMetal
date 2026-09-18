#!/usr/bin/env python3
"""
Draws VanityMetal.iconset from scratch (no assets, no external art).
Run from the repo root:  python3 Tools/make_icon.py
Then build.sh turns the iconset into VanityMetal.icns with iconutil.
"""
import os, math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
VOID = (5, 7, 14)
DEEP = (11, 18, 36)
CYAN = (34, 232, 255)
MAGENTA = (255, 61, 203)
VIOLET = (157, 111, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def base_layer():
    img = Image.new("RGB", (S, S), VOID)
    d = ImageDraw.Draw(img)
    # vertical gradient
    for y in range(S):
        t = y / S
        d.line([(0, y), (S, y)], fill=lerp(VOID, DEEP, math.sin(t * math.pi) * 0.9))
    return img


def screen(a, b):
    """Screen blend, so glows add without clipping to white."""
    pa, pb = a.load(), b.load()
    out = Image.new("RGB", a.size)
    po = out.load()
    for y in range(a.size[1]):
        for x in range(a.size[0]):
            ra, ga, ba = pa[x, y]
            rb, gb, bb = pb[x, y]
            po[x, y] = (255 - (255 - ra) * (255 - rb) // 255,
                        255 - (255 - ga) * (255 - gb) // 255,
                        255 - (255 - ba) * (255 - bb) // 255)
    return out


def perspective_grid(img):
    layer = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    horizon = int(S * 0.56)
    vpx = S // 2
    depth = S - horizon
    for i in range(1, 22):
        y = horizon + depth / i
        if y > S:
            continue
        a = min(1.0, (y - horizon) / depth * 1.4)
        d.line([(0, y), (S, y)], fill=tuple(int(c * a * 0.55) for c in CYAN), width=3)
    for i in range(-9, 10):
        x2 = vpx + i * S * 0.24
        d.line([(vpx, horizon), (x2, S)], fill=tuple(int(c * 0.30) for c in CYAN), width=3)
    layer = layer.filter(ImageFilter.GaussianBlur(1.5))
    return screen(img, layer)


def bolt_layer():
    """A neon lightning bolt — the mark."""
    layer = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = S * 0.5, S * 0.47
    w, h = S * 0.30, S * 0.44
    pts = [
        (cx + w * 0.30, cy - h * 0.62),
        (cx - w * 0.72, cy + h * 0.10),
        (cx - w * 0.06, cy + h * 0.10),
        (cx - w * 0.34, cy + h * 0.66),
        (cx + w * 0.76, cy - h * 0.14),
        (cx + w * 0.08, cy - h * 0.14),
    ]
    d.polygon(pts, fill=CYAN)
    glow = layer.filter(ImageFilter.GaussianBlur(S // 30))
    glow2 = layer.filter(ImageFilter.GaussianBlur(S // 10))
    out = screen(glow2, glow)
    return screen(out, layer)


def ring_layer():
    layer = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    m = S * 0.13
    d.ellipse([m, m, S - m, S - m], outline=MAGENTA, width=int(S * 0.012))
    d.arc([m * 1.35, m * 1.35, S - m * 1.35, S - m * 1.35],
          start=205, end=335, fill=VIOLET, width=int(S * 0.009))
    glow = layer.filter(ImageFilter.GaussianBlur(S // 40))
    return screen(screen(layer, glow), layer.filter(ImageFilter.GaussianBlur(S // 14)))


def rounded_mask():
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)
    return mask


def build():
    img = base_layer()
    img = perspective_grid(img)
    img = screen(img, ring_layer())
    img = screen(img, bolt_layer())

    # vignette
    vig = Image.new("L", (S, S), 0)
    dv = ImageDraw.Draw(vig)
    for i in range(60):
        t = i / 60
        r = S * (0.42 + 0.62 * t)
        dv.ellipse([S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r], outline=int(70 * t))
    vig = vig.filter(ImageFilter.GaussianBlur(S // 16))
    img = Image.composite(Image.new("RGB", (S, S), VOID), img, vig)

    rgba = img.convert("RGBA")
    rgba.putalpha(rounded_mask())

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "Resources", "VanityMetal.iconset")
    os.makedirs(out, exist_ok=True)
    sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for size, scale in sizes:
        px = size * scale
        name = "icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else "")
        rgba.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
    rgba.resize((512, 512), Image.LANCZOS).save(
        os.path.join(os.path.dirname(out), "icon-preview.png"))
    print("wrote", out)


if __name__ == "__main__":
    build()
