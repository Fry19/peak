#!/usr/bin/env python3
"""Download USGS 3DEP bare-ground terrain around a point as .pkdem patches, for peakbench.

The app uses USGS 3DEP's 1/3 arc-second (about 10 m) terrain model, where there is one
(the United States and its territories), for the ground under trails: their climbs, the
line drawn on the mountain and the maps. It's a bare-earth model, without trees and
buildings, unlike Copernicus. This fetches what the app would: the 512-pixel blocks of
each 1° tile within the radius, by range request from the public bucket, decoded and
written as one .pkdem patch per 1° cell, USGS13_<cell>.pkdem. Pass the directory to
peakbench with --ground.

    python3 Tools/fetch_ground.py --lat 35.654 --lon -83.444 --radius-km 10 --out GROUND-smokies

Needs numpy and imagecodecs (pip install -r Tools/requirements.txt). Cells USGS has no
tile for are skipped. USGS 3DEP data is in the public domain; credit: U.S. Geological Survey.
"""

import argparse
import math
import os
import struct
import sys
import urllib.error
import urllib.request

import imagecodecs
import numpy as np

from fetch_dem import HEADER_SIZE, MAGIC, VERSION, tile_name, tiles_around

BUCKET = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current"
HEAD_BYTES = 16_384   # what the app reads; the directories of a 3DEP tile fit in it


def usgs_url(south, west):
    # Named after the tile's north-west corner: n36w084 is 35-36°N, 84-83°W.
    north = south + 1
    stem = f"{'n' if north >= 0 else 's'}{abs(north):02d}{'e' if west >= 0 else 'w'}{abs(west):03d}"
    return f"{BUCKET}/{stem}/USGS_13_{stem}.tif"


def get(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end - 1}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def read_header(head):
    """The full-resolution image's size, blocks and georeference from a classic TIFF's start."""
    assert head[:4] == b"II*\0", "not a little-endian classic TIFF"
    off = struct.unpack_from("<I", head, 4)[0]
    n = struct.unpack_from("<H", head, off)[0]
    sizes = {3: 2, 4: 4, 12: 8, 2: 1}
    fmts = {3: "H", 4: "I", 12: "d", 2: "c"}
    tags = {}
    for i in range(n):
        tag, typ, cnt, val = struct.unpack_from("<HHII", head, off + 2 + 12 * i)
        size = sizes.get(typ, 1) * cnt
        at = off + 2 + 12 * i + 8 if size <= 4 else val
        if typ == 2:
            tags[tag] = head[at:at + cnt].split(b"\0")[0].decode()
        elif typ in fmts:
            tags[tag] = struct.unpack_from(f"<{cnt}{fmts[typ]}", head, at)
    assert tags[259][0] == 5 and tags[339][0] == 3 and tags[317][0] == 3, "expected LZW floats, floating-point predictor"
    raster_type = 1
    keys = tags.get(34735, ())
    for i in range(4, len(keys), 4):
        if keys[i] == 1025:
            raster_type = keys[i + 3]
    step_lon, step_lat = tags[33550][0], tags[33550][1]
    origin_lon, origin_lat = tags[33922][3], tags[33922][4]
    if raster_type == 1:
        origin_lon += step_lon / 2
        origin_lat -= step_lat / 2
    return dict(width=tags[256][0], height=tags[257][0], tile=tags[322][0], offsets=tags[324], counts=tags[325],
                nodata=float(tags.get(42113, "-999999")), origin_lat=origin_lat, origin_lon=origin_lon,
                step_lat=step_lat, step_lon=step_lon)


def write_patch(path, south, west, heights, origin_lat, origin_lon, step_lat, step_lon):
    """A .pkdem patch; NaN heights become its no-data value (Int16.min), unlike fetch_dem's
    whole tiles, which have none."""
    rows, cols = heights.shape
    data = np.where(np.isnan(heights), -32768, np.clip(np.rint(np.nan_to_num(heights)), -32767, 32767)).astype("<i2")
    header = MAGIC + struct.pack("<IiiII4d", VERSION, south, west, rows, cols, origin_lat, origin_lon, step_lat, step_lon)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(header.ljust(HEADER_SIZE, b"\0"))
        f.write(data.tobytes())
    os.replace(tmp, path)


def decode_block(data, size):
    raw = np.frombuffer(imagecodecs.lzw_decode(data), np.uint8)[:size * size * 4].reshape(size, size * 4)
    # Floating-point predictor: bytes differenced along the row, most significant bytes first.
    raw = np.cumsum(raw, axis=1, dtype=np.uint8)
    return raw.reshape(size, 4, size).transpose(0, 2, 1).copy().view(">f4")[:, :, 0].astype(np.float64)


def fetch_patch(south, west, lat, lon, radius_km, out_dir):
    url = usgs_url(south, west)
    try:
        h = read_header(get(url, 0, HEAD_BYTES))
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):
            return "no USGS tile"
        raise
    dlat = radius_km / 111.0
    dlon = radius_km / (111.0 * max(math.cos(math.radians(lat)), 0.05))
    t = h["tile"]
    across = (h["width"] + t - 1) // t

    def rows(a, b):
        return max(0, int((h["origin_lat"] - b) / h["step_lat"])), min(h["height"] - 1, int((h["origin_lat"] - a) / h["step_lat"]) + 1)

    def cols(a, b):
        return max(0, int((a - h["origin_lon"]) / h["step_lon"])), min(h["width"] - 1, int((b - h["origin_lon"]) / h["step_lon"]) + 1)

    # The box around the point, within this cell.
    r0, r1 = rows(max(lat - dlat, south), min(lat + dlat, south + 1))
    c0, c1 = cols(max(lon - dlon, west), min(lon + dlon, west + 1))
    if r0 > r1 or c0 > c1:
        return "outside the radius"
    by0, by1, bx0, bx1 = r0 // t, r1 // t, c0 // t, c1 // t
    heights = np.full(((by1 - by0 + 1) * t, (bx1 - bx0 + 1) * t), np.nan)
    fetched = 0
    for by in range(by0, by1 + 1):
        for bx in range(bx0, bx1 + 1):
            i = by * across + bx
            data = get(url, h["offsets"][i], h["offsets"][i] + h["counts"][i])
            fetched += len(data)
            heights[(by - by0) * t:(by - by0 + 1) * t, (bx - bx0) * t:(bx - bx0 + 1) * t] = decode_block(data, t)
    # Only the image's own pixels; voids are the file's nodata or far below any land.
    heights = heights[:h["height"] - by0 * t, :h["width"] - bx0 * t]
    heights[(heights == h["nodata"]) | (heights < -1000) | ~np.isfinite(heights)] = np.nan
    write_patch(os.path.join(out_dir, f"USGS13_{tile_name(south, west)}.pkdem"), south, west, heights,
                h["origin_lat"] - by0 * t * h["step_lat"], h["origin_lon"] + bx0 * t * h["step_lon"],
                h["step_lat"], h["step_lon"])
    land = heights[np.isfinite(heights)]
    return (f"{(by1 - by0 + 1) * (bx1 - bx0 + 1)} blocks, {fetched / 1e6:.1f} MB, "
            f"{heights.shape[0]}x{heights.shape[1]}, {land.min():.0f}–{land.max():.0f} m")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--lat", type=float, required=True)
    p.add_argument("--lon", type=float, required=True)
    p.add_argument("--radius-km", type=float, default=10)
    p.add_argument("--out", default="GROUND")
    args = p.parse_args()

    os.makedirs(args.out, exist_ok=True)
    cells = tiles_around(args.lat, args.lon, args.radius_km)
    print(f"{len(cells)} cells for {args.radius_km:g} km around {args.lat}, {args.lon}")
    for south, west in cells:
        print(f"  {tile_name(south, west)}: ", end="", flush=True)
        print(fetch_patch(south, west, args.lat, args.lon, args.radius_km, args.out), flush=True)


if __name__ == "__main__":
    sys.exit(main())
