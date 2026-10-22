#!/usr/bin/env python3
"""Render the app icon: a summit at dusk with its crest traced and labeled, as in the AR view.

    python3 Tools/make_icon.py

Writes AppIcon.png and AppIcon-Tinted.png (grayscale, for the tinted home screen) into
Peak/Assets.xcassets/AppIcon.appiconset. The colors are the overlay's: ice-white crest
lines, nearer ridges brighter, and the gold accent for the label marker.

Needs numpy and pillow (pip install -r Tools/requirements.txt).
"""

import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = 1024
SS = 4  # supersampling; the final downscale does the antialiasing
S = OUT * SS

ICE = np.array([0.86, 0.94, 1.0])
WHITE = np.array([1.0, 1.0, 1.0])
GOLD = np.array([1.0, 0.84, 0.45])


def hexc(h):
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


def value_noise(xs, seed, octaves=5, base_freq=6, gain=0.5):
    rng = np.random.default_rng(seed)
    out = np.zeros_like(xs)
    amp, freq, total = 1.0, base_freq, 0.0
    for _ in range(octaves):
        pts = rng.uniform(-1, 1, int(freq) + 3)
        t = xs * freq
        i = np.floor(t).astype(int)
        f = t - i
        f = f * f * (3 - 2 * f)
        out += amp * (pts[i] * (1 - f) + pts[i + 1] * f)
        total += amp
        amp *= gain
        freq *= 2
    return out / total


def profile(anchors, xs, seed, rough, calm=None):
    """A ridge's height (y, down) at each x: anchors plus fractal roughness, lightly smoothed.
    `calm` = (x, radius) quiets the roughness around a summit so its tip stays clean."""
    ax, ay = zip(*anchors)
    ys = np.interp(xs, ax, ay)
    n = value_noise(xs, seed)
    if calm is not None:
        cx, cr = calm
        n *= np.clip(np.abs(xs - cx) / cr, 0.25, 1)
    ys = ys + rough * n
    k = 9
    pad = np.pad(ys, k, mode="edge")
    return np.convolve(pad, np.ones(2 * k + 1) / (2 * k + 1), mode="same")[k:-k]


def spline(ctrl, n=60):
    """Catmull-Rom through the control points."""
    p = np.array([ctrl[0]] + list(ctrl) + [ctrl[-1]], dtype=float)
    out = []
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for t in np.linspace(0, 1, n, endpoint=False):
            t2, t3 = t * t, t * t * t
            out.append(0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(p[-2])
    return np.array(out)


def px(points):
    return [(x * S, y * S) for x, y in points]


def mask_poly(points):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(px(points), fill=255)
    return np.asarray(m, dtype=np.float32) / 255


def mask_line(points, width, blur=0):
    """A polyline `width` output pixels wide, with round joins and caps."""
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    w = width * SS
    pts = px(points)
    d.line(pts, fill=255, width=int(round(w)))
    r = w / 2
    for x, y in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    if blur:
        m = m.filter(ImageFilter.GaussianBlur(blur * SS))
    return np.asarray(m, dtype=np.float32) / 255


def mask_disc(cx, cy, r, blur=0):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse([(cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S], fill=255)
    if blur:
        m = m.filter(ImageFilter.GaussianBlur(blur * SS))
    return np.asarray(m, dtype=np.float32) / 255


def over(img, color, alpha):
    a = alpha[..., None]
    return img * (1 - a) + np.broadcast_to(color, img.shape) * a


def add(img, color, alpha):
    return img + np.broadcast_to(color, img.shape) * alpha[..., None]


def vgrad(stops):
    ys = np.linspace(0, 1, S)
    cols = np.stack([np.interp(ys, [p for p, _ in stops], [c[i] for _, c in stops]) for i in range(3)], -1)
    return np.broadcast_to(cols[:, None, :], (S, S, 3)).copy()


def render():
    """The icon as linear-ish RGB floats, S×S. Coordinates are fractions of the icon, y down."""
    xs = np.linspace(-0.02, 1.02, 1200)
    yy, xx = np.mgrid[0:S, 0:S] / S
    img = vgrad([(0, hexc("04060c")), (0.30, hexc("0a1120")), (0.60, hexc("1c2b4a")), (1, hexc("1c2b4a"))])

    # Last light low on the horizon, behind the ridges.
    img = add(img, hexc("ff9a4a"), np.exp(-(((xx - 0.84) / 0.40) ** 2 + ((yy - 0.64) / 0.15) ** 2)) * 0.20)
    img = add(img, hexc("6a85c0"), np.exp(-((yy - 0.6) / 0.12) ** 2) * 0.06)

    far = profile([(-0.02, 0.585), (0.10, 0.545), (0.22, 0.575), (0.36, 0.53), (0.52, 0.565), (0.74, 0.52),
                   (0.88, 0.545), (1.02, 0.53)], xs, 3, 0.02)
    mid = profile([(-0.02, 0.64), (0.09, 0.585), (0.22, 0.625), (0.40, 0.65), (0.62, 0.635), (0.84, 0.575),
                   (1.02, 0.61)], xs, 7, 0.024)
    near = profile([(-0.02, 0.76), (0.08, 0.725), (0.18, 0.665), (0.28, 0.59), (0.355, 0.505), (0.395, 0.52),
                    (0.47, 0.405), (0.585, 0.225), (0.62, 0.30), (0.645, 0.35), (0.685, 0.385), (0.72, 0.465),
                    (0.80, 0.555), (0.90, 0.615), (1.02, 0.645)], xs, 11, 0.026, calm=(0.585, 0.10))
    i = np.argmin(near)
    sx, sy = xs[i], near[i]

    def crest(ys):
        return list(zip(xs, ys))

    def ground(ys):
        return crest(ys) + [(1.02, 1.05), (-0.02, 1.05)]

    # Far to near: each fill hides the lines behind it, and nearer crests are brighter.
    img = over(img, hexc("16223e"), mask_poly(ground(far)))
    img = add(img, ICE, mask_line(crest(far), 14, 6) * 0.05)
    img = over(img, ICE, mask_line(crest(far), 3.2) * 0.30)
    img = over(img, vgrad([(0.55, hexc("101a30")), (1, hexc("0a1122"))]), mask_poly(ground(mid)))
    img = add(img, ICE, mask_line(crest(mid), 18, 8) * 0.08)
    img = over(img, ICE, mask_line(crest(mid), 4.2) * 0.50)
    img = over(img, vgrad([(0.22, hexc("0b1120")), (1, hexc("04070e"))]), mask_poly(ground(near)))

    # An arete runs from the summit toward the viewer; the face right of it catches the afterglow,
    # and its top holds the sun longest.
    ar = spline([(sx, sy), (sx - 0.018, 0.34), (sx - 0.035, 0.47), (sx - 0.07, 0.64), (sx - 0.10, 0.85),
                 (sx - 0.12, 1.05)], 80)
    ar[:, 0] += 0.006 * value_noise(np.clip(ar[:, 1], 0, 1), 5, base_freq=10)
    right = xs >= sx
    face = mask_poly(list(zip(xs[right], near[right])) + [(1.02, 1.05)] + [tuple(p) for p in ar[::-1]])
    img = over(img, vgrad([(0.22, hexc("1b2238")), (0.55, hexc("10162a")), (1, hexc("06090f"))]), face)
    alpenglow = np.exp(-(((xx - sx - 0.03) / 0.10) ** 2 + ((yy - sy - 0.05) / 0.13) ** 2))
    img = add(img, hexc("ff8a4a"), alpenglow * face * 0.10)
    fade = np.clip(1 - (yy - sy) / 0.55, 0, 1) ** 1.5
    img = add(img, ICE, mask_line([tuple(p) for p in ar], 3.5) * fade * 0.38)

    # The skyline: soft glow, halo, bright core.
    img = add(img, ICE, mask_line(crest(near), 56, 24) * 0.20)
    img = add(img, ICE, mask_line(crest(near), 16, 5) * 0.30)
    img = over(img, WHITE, mask_line(crest(near), 8.5) * 0.97)

    # The summit's label: a leader line up to a gold marker.
    top = 0.105
    lead = [(sx, sy - 0.035), (sx, top + 0.03)]
    img = add(img, GOLD, mask_line(lead, 14, 7) * 0.10)
    img = over(img, GOLD, mask_line(lead, 5) * 0.85)
    img = add(img, GOLD, mask_disc(sx, top, 0.05, 30) * 0.34)
    img = over(img, GOLD, mask_disc(sx, top, 0.021))
    return np.clip(img, 0, 1)


def to_image(a):
    return Image.fromarray((a * 255 + 0.5).astype(np.uint8)).resize((OUT, OUT), Image.LANCZOS)


def tinted(img):
    """Grayscale for the tinted home screen: the system maps brightness to the tint, so the
    lines and marker go full bright and the dark masses stay dark."""
    lum = 0.2126 * img[..., 0] + 0.7152 * img[..., 1] + 0.0722 * img[..., 2]
    lum = np.clip((lum - 0.02) / 0.85, 0, 1) ** 0.9
    return np.repeat(lum[..., None], 3, -1)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=os.path.join(here, "..", "Peak", "Assets.xcassets", "AppIcon.appiconset"))
    args = ap.parse_args()
    img = render()
    to_image(img).save(os.path.join(args.out, "AppIcon.png"), optimize=True)
    to_image(tinted(img)).save(os.path.join(args.out, "AppIcon-Tinted.png"), optimize=True)
    print(f"wrote AppIcon.png and AppIcon-Tinted.png to {os.path.normpath(args.out)}")


if __name__ == "__main__":
    main()
