#!/usr/bin/env python3
"""Render the app icon: the Matterhorn from Gornergrat at first light, traced from the terrain
and labeled as in the AR view.

    python3 Tools/fetch_dem.py --lat 45.9837 --lon 7.7856 --radius-km 100 --out DEM
    python3 Tools/make_icon.py --dem DEM

The skyline and ridges are ray-marched through Copernicus GLO-30 tiles the way Horizon.swift
does it (Earth curvature, refraction k = 0.13). A 30 m model blunts the Matterhorn's needle, so
its top is restored to the surveyed 4478 m with a concave tip that meets the model's own flanks.

Writes AppIcon.png and AppIcon-Tinted.png (grayscale, for the tinted home screen) into
Peak/Assets.xcassets/AppIcon.appiconset. The colors are the overlay's: an ice-white skyline,
nearer ridges brighter, and the gold accent for the label marker.

Needs numpy and pillow (pip install -r Tools/requirements.txt).
"""

import argparse
import math
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = 1024
SS = 4  # the skyline and marker are drawn at 4×; the final downscale antialiases
S = OUT * SS
T = 2048  # terrain fill and inner ridges

VIEWER = (45.983333, 7.784722)        # Gornergrat, the top of the ridge
EYE = 2.0                             # meters above the terrain
SUMMIT = (45.976389, 7.658611, 4478)  # Matterhorn (OSM)
FOV = 14.0                            # degrees across the icon, both ways
SUMMIT_AT = (0.50, 0.25)              # where the summit sits in the icon
SUN = (100.0, 6.0)                    # azimuth, elevation: just after sunrise

R_EARTH = 6_371_000.0
REFRACTION = 0.13
MAX_DISTANCE = 90_000.0
SAMPLES = 4200

ICE = np.array([0.86, 0.94, 1.0])
WHITE = np.array([1.0, 1.0, 1.0])
GOLD = np.array([1.0, 0.84, 0.45])


def hexc(h):
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


# Terrain

class Terrain:
    """The .pkdem tiles covering a box, as one grid of heights."""

    STEP = 1 / 3600

    def __init__(self, dem_dir, south, north, west, east):
        souths = range(math.floor(south), math.floor(north) + 1)
        wests = range(math.floor(west), math.floor(east) + 1)
        self.lat0, self.lon0 = max(souths) + 1, min(wests)
        rows = []
        for s in reversed(souths):
            row = []
            for w in wests:
                name = f"{'N' if s >= 0 else 'S'}{abs(s):02d}{'E' if w >= 0 else 'W'}{abs(w):03d}.pkdem"
                path = os.path.join(dem_dir, name)
                if not os.path.exists(path):
                    sys.exit(f"missing {path}: fetch the tiles with\n"
                             f"  python3 Tools/fetch_dem.py --lat {VIEWER[0]} --lon {VIEWER[1]} --radius-km 100 --out {dem_dir}")
                with open(path, "rb") as f:
                    header = f.read(64)
                    _, so, we, nr, nc, olat, olon, slat, slon = struct.unpack("<IiiII4d", header[4:56])
                    if (nr, nc) != (3600, 3600) or abs(olat - (s + 1)) > 1e-9 or abs(olon - w) > 1e-9:
                        sys.exit(f"{path}: expected a 1″ tile with its first pixel on the corner")
                    row.append(np.frombuffer(f.read(nr * nc * 2), dtype="<i2").reshape(nr, nc))
            rows.append(np.concatenate(row, axis=1))
        self.h = np.concatenate(rows, axis=0).astype(np.float32)

    def height(self, lat, lon):
        r = (self.lat0 - lat) / self.STEP
        c = (lon - self.lon0) / self.STEP
        r0 = np.clip(np.floor(r).astype(np.int64), 0, self.h.shape[0] - 2)
        c0 = np.clip(np.floor(c).astype(np.int64), 0, self.h.shape[1] - 2)
        fr, fc = np.clip(r - r0, 0, 1), np.clip(c - c0, 0, 1)
        h = self.h
        return ((h[r0, c0] * (1 - fc) + h[r0, c0 + 1] * fc) * (1 - fr)
                + (h[r0 + 1, c0] * (1 - fc) + h[r0 + 1, c0 + 1] * fc) * fr)

    def normal(self, lat, lon, d=3 / 3600):
        """Unit surface normals (east, north, up), over a baseline of ±d degrees."""
        mlat = 111_320.0
        mlon = mlat * np.cos(np.radians(lat))
        gx = (self.height(lat, lon + d) - self.height(lat, lon - d)) / (2 * d * mlon)
        gy = (self.height(lat + d, lon) - self.height(lat - d, lon)) / (2 * d * mlat)
        n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
        return n / np.linalg.norm(n, axis=-1, keepdims=True)


def destination(lat, lon, azimuth, distance):
    p1, l1, a = math.radians(lat), math.radians(lon), np.radians(azimuth)
    delta = distance / R_EARTH
    p2 = np.arcsin(math.sin(p1) * np.cos(delta) + math.cos(p1) * np.sin(delta) * np.cos(a))
    l2 = l1 + np.arctan2(np.sin(a) * np.sin(delta) * math.cos(p1), np.cos(delta) - math.sin(p1) * np.sin(p2))
    return np.degrees(p2), np.degrees(l2)


def elevation_angle(distance, height, eye):
    """Degrees, on a sphere enlarged for refraction (R' = R / (1 - k)), as Horizon.swift does."""
    re = R_EARTH / (1 - REFRACTION)
    theta = distance / re
    r = re + height
    return np.degrees(np.arctan2(np.cos(theta) * r - (re + eye), np.sin(theta) * r))


def look_at(eye, lat, lon, height):
    p1, p2 = math.radians(VIEWER[0]), math.radians(lat)
    dl = math.radians(lon - VIEWER[1])
    az = math.degrees(math.atan2(math.sin(dl) * math.cos(p2),
                                 math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl))) % 360
    d = R_EARTH * math.acos(min(1.0, math.sin(p1) * math.sin(p2) + math.cos(p1) * math.cos(p2) * math.cos(dl)))
    return az, float(elevation_angle(d, height, eye))


def march(terrain, eye, azimuths, distances, chunk=256):
    """Elevation angle and position of every sample along every ray, a chunk of rays at a time."""
    for c0 in range(0, len(azimuths), chunk):
        lat, lon = destination(VIEWER[0], VIEWER[1], azimuths[c0:c0 + chunk, None], distances[None, :])
        yield c0, elevation_angle(distances[None, :], terrain.height(lat, lon), eye), lat, lon


def restore_tip(azimuths, skyline, apex_az, apex_el, power=0.85, reach=1.2):
    """Raise the skyline near the summit to apex_el - c·|x|^power (x in degrees from the apex),
    each side with the c that just meets the terrain's flank, and only out to where it meets."""
    out = skyline.copy()
    for side in (-1, 1):
        x = (azimuths - apex_az) * side
        flank = (x > 0.1) & (x < reach)
        ratio = (apex_el - skyline[flank]) / x[flank] ** power
        k = int(np.argmin(ratio))
        c, touch = ratio[k], x[flank][k]
        near = (x >= 0) & (x <= touch)
        out[near] = np.maximum(skyline[near], apex_el - c * x[near] ** power)
    return out


# Drawing

def px(points):
    return [(x * S, y * S) for x, y in points]


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


def upscale(a, mode=Image.BILINEAR):
    """A T×T float array to S×S."""
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize((S, S), mode))


def dilate(a, radius):
    """Max filter over a square of side 2·radius + 1."""
    out = a.copy()
    for axis in (0, 1):
        src = out.copy()
        n = src.shape[axis]
        for k in range(1, radius + 1):
            lo, hi = [slice(None)] * 2, [slice(None)] * 2
            lo[axis], hi[axis] = slice(k, None), slice(None, n - k)
            lo, hi = tuple(lo), tuple(hi)
            np.maximum(out[lo], src[hi], out=out[lo])
            np.maximum(out[hi], src[lo], out=out[hi])
    return out


def over(img, color, alpha):
    a = alpha[..., None]
    return img * (1 - a) + np.broadcast_to(color, img.shape) * a


def add(img, color, alpha):
    return img + np.broadcast_to(color, img.shape) * alpha[..., None]


def mix(a, b, t):
    return a + (b - a) * t[..., None]


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def render(dem_dir):
    # The view: square pixels in angle, the summit placed at SUMMIT_AT.
    probe = Terrain(dem_dir, VIEWER[0] - 0.01, VIEWER[0] + 0.01, VIEWER[1] - 0.01, VIEWER[1] + 0.01)
    eye = float(probe.height(np.array(VIEWER[0]), np.array(VIEWER[1]))) + EYE
    apex_az, apex_el = look_at(eye, *SUMMIT)
    az_left = apex_az - SUMMIT_AT[0] * FOV
    el_top = apex_el + SUMMIT_AT[1] * FOV
    corners = [destination(VIEWER[0], VIEWER[1], a, MAX_DISTANCE) for a in (az_left, az_left + FOV / 2, az_left + FOV)]
    lats = [VIEWER[0]] + [float(c[0]) for c in corners]
    lons = [VIEWER[1]] + [float(c[1]) for c in corners]
    terrain = Terrain(dem_dir, min(lats), max(lats), min(lons), max(lons))
    distances = 25.0 * (MAX_DISTANCE / 25.0) ** (np.arange(SAMPLES) / (SAMPLES - 1))

    def x_of(az):
        return (az - az_left) / FOV

    def y_of(el):
        return (el_top - el) / FOV

    # The skyline, one ray per output column, with the summit's needle put back.
    sky_az = az_left + (np.arange(S) + 0.5) / S * FOV
    skyline = np.empty(S)
    for c0, angle, _, _ in march(terrain, eye, sky_az, distances):
        skyline[c0:c0 + len(angle)] = angle.max(axis=1)
    raw = skyline.copy()
    skyline = restore_tip(sky_az, skyline, apex_az, apex_el)
    # Soften the 30 m model's facets, but not the tip.
    sigma = 0.06 / FOV * S
    k = np.exp(-0.5 * (np.arange(-4 * int(sigma), 4 * int(sigma) + 1) / sigma) ** 2)
    smooth = np.convolve(np.pad(skyline, len(k) // 2, mode="edge"), k / k.sum(), mode="valid")
    keep = np.clip(1 - np.abs(sky_az - apex_az) / 0.25, 0, 1)
    skyline = keep * skyline + (1 - keep) * smooth
    print(f"summit {apex_el:.2f}° at {apex_az:.2f}°; terrain reaches {raw.max():.2f}°, restored {skyline.max():.2f}°")

    # The terrain: what each pixel hits, how far, and how it faces the sun.
    t_az = az_left + (np.arange(T) + 0.5) / T * FOV
    t_el = el_top - (np.arange(T) + 0.5) / T * FOV
    depth = np.full((T, T), np.inf, dtype=np.float32)
    hit_lat = np.zeros((T, T))
    hit_lon = np.zeros((T, T))
    for c0, angle, lat, lon in march(terrain, eye, t_az, distances):
        reach = np.maximum.accumulate(angle, axis=1)
        for j in range(angle.shape[0]):
            # The first sample whose running maximum reaches the row's angle.
            k = np.searchsorted(reach[j], t_el[::-1])[::-1]
            hit = k < SAMPLES
            depth[hit, c0 + j] = distances[k[hit]]
            hit_lat[hit, c0 + j] = lat[j, k[hit]]
            hit_lon[hit, c0 + j] = lon[j, k[hit]]
    ground = np.isfinite(depth)
    # Fill under the restored tip with the summit's own face.
    tip_el = np.interp(t_az, sky_az, skyline)
    tip = np.zeros((T, T), dtype=bool)
    for c in range(T):
        rows = np.nonzero(ground[:, c])[0]
        if len(rows) == 0:
            continue
        top, new_top = rows[0], int(np.ceil((el_top - tip_el[c]) / FOV * T - 0.5))
        if new_top < top:
            for a in (depth, hit_lat, hit_lon):
                a[new_top:top, c] = a[top, c]
            ground[new_top:top, c] = True
            tip[new_top:top, c] = True

    sun = np.array([math.sin(math.radians(SUN[0])) * math.cos(math.radians(SUN[1])),
                    math.cos(math.radians(SUN[0])) * math.cos(math.radians(SUN[1])),
                    math.sin(math.radians(SUN[1]))])
    lit = np.zeros((T, T), dtype=np.float32)
    elev = np.zeros((T, T), dtype=np.float32)
    lit[ground] = np.clip((terrain.normal(hit_lat[ground], hit_lon[ground]) * sun).sum(-1), 0, 1)
    elev[ground] = terrain.height(hit_lat[ground], hit_lon[ground])

    # Ridges inside the view: where a nearer crest hides terrain much farther away.
    d = np.where(ground, depth, 1e12)
    edge = np.zeros((T, T), dtype=bool)
    above = d[:-1]
    edge[1:] |= ground[:-1] & (above > 1.35 * d[1:]) & (above - d[1:] > 600)
    for near, far in ((np.s_[:, 1:], np.s_[:, :-1]), (np.s_[:, :-1], np.s_[:, 1:])):
        edge[near] |= ground[near] & ground[far] & (d[far] > 1.35 * d[near]) & (d[far] - d[near] > 600)
    band = np.select([d < 3000, d < 10000, d < 30000], [0.95, 0.75, 0.55], 0.35).astype(np.float32)

    # Paint. Sky first: night overhead, the anti-twilight glow low in the west.
    yy = (np.arange(S)[:, None] + 0.5) / S
    xx = (np.arange(S)[None, :] + 0.5) / S
    horizon = float(np.median(y_of(skyline)))  # where the skyline runs, beside the peak
    sky_stops = [(0, hexc("04060c")), (horizon - 0.36, hexc("0a1120")), (horizon - 0.02, hexc("1c2b4a")), (1, hexc("1c2b4a"))]
    ys = yy[:, 0]
    sky = np.stack([np.interp(ys, [p for p, _ in sky_stops], [c[i] for _, c in sky_stops]) for i in range(3)], -1)
    img = np.broadcast_to(sky[:, None, :], (S, S, 3)).copy()
    img = add(img, hexc("ff9a4a"), (np.exp(-(((xx - 0.80) / 0.45) ** 2 + ((yy - horizon) / 0.12) ** 2)) * 0.10))
    img = add(img, hexc("6a85c0"), np.broadcast_to(np.exp(-((yy - horizon + 0.02) / 0.10) ** 2) * 0.06, (S, S)))

    # Ground: darker near, hazier far; faces toward the sun a little lighter, the high ones warm.
    far = np.clip(np.log(np.where(ground, depth, 1e9) / 900) / math.log(60000 / 900), 0, 1) ** 0.85
    col = mix(np.broadcast_to(hexc("04070e"), (T, T, 3)), np.broadcast_to(hexc("17223d"), (T, T, 3)), far)
    col = col + hexc("2f4270")[None, None, :] * (lit * 0.50 * (1 - 0.5 * far))[..., None]
    alpen = smoothstep(3500, 4400, elev) * lit
    col = col + hexc("ff8a4a")[None, None, :] * (alpen * 0.30)[..., None]
    shade = 1 - 0.6 * smoothstep(0.5, 1.0, (np.arange(T)[:, None] + 0.5) / T)
    col = col * shade[..., None]
    # The restored tip copies its columns' tops; blur the streaks away across the rows.
    kernel = np.exp(-0.5 * (np.arange(-24, 25) / 8) ** 2)
    kernel /= kernel.sum()
    for r in np.nonzero(tip.any(axis=1))[0]:
        soft = np.stack([np.convolve(np.pad(col[r, :, i], 24, mode="edge"), kernel, mode="valid") for i in range(3)], -1)
        col[r] = np.where(tip[r, :, None], soft, col[r])
    g = upscale(ground.astype(np.float32))
    img = over(img, np.stack([upscale(col[..., i]) for i in range(3)], -1), np.clip(g, 0, 1))

    # Inner ridges, faint and thin; nearer ones brighter.
    e = dilate(upscale(edge.astype(np.float32), Image.NEAREST), int(1.6 * SS)) > 0.5
    a = dilate(upscale(np.where(edge, band, 0).astype(np.float32), Image.NEAREST), int(1.6 * SS))
    soft = np.asarray(Image.fromarray((e * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2 * SS)), dtype=np.float32) / 255
    glow = np.asarray(Image.fromarray((e * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6 * SS)), dtype=np.float32) / 255
    img = add(img, ICE, glow * a * 0.10)
    img = over(img, ICE, soft * a * 0.42)

    # The skyline: soft glow, halo, bright core.
    line = list(zip(x_of(sky_az[::2]), y_of(skyline[::2])))
    img = add(img, ICE, mask_line(line, 56, 24) * 0.20)
    img = add(img, ICE, mask_line(line, 16, 5) * 0.30)
    img = over(img, WHITE, mask_line(line, 8.5) * 0.97)

    # The summit's label: a leader line up to a gold marker.
    sx, sy = x_of(apex_az), y_of(apex_el)
    top = sy - 0.13
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
    ap.add_argument("--dem", required=True, help="directory of .pkdem tiles around Zermatt")
    ap.add_argument("--out", default=os.path.join(here, "..", "Peak", "Assets.xcassets", "AppIcon.appiconset"))
    args = ap.parse_args()
    img = render(args.dem)
    to_image(img).save(os.path.join(args.out, "AppIcon.png"), optimize=True)
    to_image(tinted(img)).save(os.path.join(args.out, "AppIcon-Tinted.png"), optimize=True)
    print(f"wrote AppIcon.png and AppIcon-Tinted.png to {os.path.normpath(args.out)}")


if __name__ == "__main__":
    main()
