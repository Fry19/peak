#!/usr/bin/env python3
"""Download Copernicus GLO-30 DEM tiles around a point and convert them to .pkdem files.

The tiles come from the public AWS Open Data bucket (no account needed). Each 1° tile
is written as a .pkdem file: a 64-byte header and Int16 heights in meters, rows from
north to south. PeakCore reads these directly.

    python3 Tools/fetch_dem.py --lat 45.9837 --lon 7.7856 --radius-km 60 --out DEM

Needs numpy, tifffile and imagecodecs (pip install -r Tools/requirements.txt).
Tiles over open ocean don't exist in the bucket; they are skipped and read as sea level.

Produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and
Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA.
"""

import argparse
import math
import os
import struct
import sys
import tempfile
import urllib.error
import urllib.request

import numpy as np
import tifffile

BUCKET = "https://copernicus-dem-30m.s3.amazonaws.com"
MAGIC = b"PKDM"
VERSION = 1
HEADER_SIZE = 64


def tile_name(south, west):
    ns = "N" if south >= 0 else "S"
    ew = "E" if west >= 0 else "W"
    return f"{ns}{abs(south):02d}{ew}{abs(west):03d}"


def copernicus_url(south, west):
    ns = "N" if south >= 0 else "S"
    ew = "E" if west >= 0 else "W"
    stem = f"Copernicus_DSM_COG_10_{ns}{abs(south):02d}_00_{ew}{abs(west):03d}_00_DEM"
    return f"{BUCKET}/{stem}/{stem}.tif"


def tiles_around(lat, lon, radius_km):
    dlat = radius_km / 111.0
    dlon = radius_km / (111.0 * max(math.cos(math.radians(lat)), 0.05))
    souths = range(math.floor(lat - dlat), math.floor(lat + dlat) + 1)
    wests = range(math.floor(lon - dlon), math.floor(lon + dlon) + 1)
    return [(s, w) for s in souths for w in wests if -90 <= s < 90]


def read_geotiff(path):
    with tifffile.TiffFile(path) as tif:
        page = tif.pages[0]
        heights = page.asarray().astype(np.float64)
        scale = page.tags["ModelPixelScaleTag"].value
        tie = page.tags["ModelTiepointTag"].value
        keys = page.tags["GeoKeyDirectoryTag"].value
    # GTRasterTypeGeoKey (1025): 1 = PixelIsArea, 2 = PixelIsPoint.
    raster_type = 1
    for i in range(4, len(keys), 4):
        if keys[i] == 1025:
            raster_type = keys[i + 3]
    step_lon, step_lat = scale[0], scale[1]
    origin_lon, origin_lat = tie[3], tie[4]
    if raster_type == 1:
        # The tie point is the corner of the first pixel; move it to its center.
        origin_lon += step_lon / 2
        origin_lat -= step_lat / 2
    return heights, origin_lat, origin_lon, step_lat, step_lon


def write_pkdem(path, south, west, heights, origin_lat, origin_lon, step_lat, step_lon):
    rows, cols = heights.shape
    data = np.clip(np.rint(heights), -32767, 32767).astype("<i2")
    header = MAGIC + struct.pack(
        "<IiiII4d", VERSION, south, west, rows, cols, origin_lat, origin_lon, step_lat, step_lon
    )
    header = header.ljust(HEADER_SIZE, b"\0")
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(header)
        f.write(data.tobytes())
    os.replace(tmp, path)


def fetch_tile(south, west, out_dir):
    name = tile_name(south, west)
    dest = os.path.join(out_dir, name + ".pkdem")
    if os.path.exists(dest):
        return "cached"
    url = copernicus_url(south, west)
    with tempfile.TemporaryDirectory() as tmp:
        tif = os.path.join(tmp, name + ".tif")
        try:
            urllib.request.urlretrieve(url, tif)
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return "no tile (sea)"
            raise
        heights, origin_lat, origin_lon, step_lat, step_lon = read_geotiff(tif)
    write_pkdem(dest, south, west, heights, origin_lat, origin_lon, step_lat, step_lon)
    return f"{heights.shape[0]}x{heights.shape[1]}, {heights.min():.0f}–{heights.max():.0f} m"


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--lat", type=float, required=True)
    p.add_argument("--lon", type=float, required=True)
    p.add_argument("--radius-km", type=float, default=100)
    p.add_argument("--out", default="DEM")
    args = p.parse_args()

    os.makedirs(args.out, exist_ok=True)
    tiles = tiles_around(args.lat, args.lon, args.radius_km)
    print(f"{len(tiles)} tiles for {args.radius_km:g} km around {args.lat}, {args.lon}")
    for south, west in tiles:
        print(f"  {tile_name(south, west)}: ", end="", flush=True)
        print(fetch_tile(south, west, args.out), flush=True)


if __name__ == "__main__":
    sys.exit(main())
