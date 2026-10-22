#!/usr/bin/env python3
"""Build the worldwide base layer (World.pkbase): coarse terrain and named peaks for the
whole world, bundled with the app so it works on first launch anywhere without a signal.

    python3 Tools/fetch_world_peaks.py --cache build/peaks --out build/world_peaks.tsv
    python3 Tools/build_base_layer.py --etopo build/etopo15 --download \\
        --peaks build/world_peaks.tsv --out build/World.pkbase

Terrain: NOAA ETOPO 2022 at 15 arc-seconds (public domain; about 5.4 GB in 288 files,
downloaded into --etopo with --download). Each 1° cell is kept at 30″ (about 0.9 km),
1′, 2′ or 4′, the coarsest that stays within a height error that is chosen so that the
terrain fits --terrain-mb: high relief gets the fine grids, plains and ice the coarse ones.
Each pixel holds the highest point of its block of 15″ pixels (--ridge 1), since a
block mean sinks every ridge and summit and with them the skyline. Heights are in steps
of --step meters, coded as differences from a planar prediction and deflated. Sea is sea
level; land below it is kept only in known depressions (the Dead Sea, the Caspian, Death
Valley and a few more), since ETOPO gives the sea floor elsewhere.

Peaks: every named OpenStreetMap natural=peak|volcano (from fetch_world_peaks.py), in 5°
blocks: id, position to 1e-5°, elevation, prominence, Wikidata item and name.

File layout (little-endian), read by PeakCore's BaseLayer:

    header, 64 bytes: "PKBL", version u32 = 1, height step f32 (m), peak count u32,
        terrain index offset u64, terrain data offset u64, peak index offset u64,
        peak data offset u64, then zeros
    terrain index: 180 × 360 cells from (south −90, west −180), row by row northward:
        rows u8, cols u8 (0 × 0: sea), end of its data u32 (relative to terrain data)
    terrain data: per cell, zlib of the residuals as u16 zigzag, low bytes then high bytes.
        Pixels are areas: pixel (r, c) is centered at south + 1 − (r + ½)/rows,
        west + (c + ½)/cols; its height is the value times the height step.
    peak index: 36 × 72 blocks of 5° from (−90, −180), row by row northward: end of the
        block's data u32 (relative to peak data)
    peak data: per block, zlib of: count u32, then columns of `count` each: id deltas
        (varint, ids ascending), lat u24 and lon u24 (1e-5° from the block's south-west
        corner), elevation i16 (−32768 when unknown), prominence u16 (0 when unknown),
        Wikidata number varint (0 when none), names (UTF-8, each ended by a zero byte).

Data: ETOPO 2022 (NOAA NCEI, public domain; doi:10.25921/fd45-gt74). Peaks
© OpenStreetMap contributors, ODbL.
"""

import argparse
import concurrent.futures
import math
import os
import re
import struct
import subprocess
import sys
import zlib

import numpy as np

CATALOG = "https://www.ngdc.noaa.gov/thredds/catalog/global/ETOPO2022/15s/15s_surface_elev_netcdf/catalog.html"
FILES = "https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/15s/15s_surface_elev_netcdf/"
SOURCE = 240                  # 15″ pixels per degree
LEVELS = [120, 60, 30, 15]    # rows per degree, finest first
MAGIC = b"PKBL"
VERSION = 1

# Land below sea level that ETOPO has right; everywhere else heights below 0 are sea floor
# (or lake beds) and read as sea level. (south, west, north, east)
DEPRESSIONS = [
    (29.0, 34.8, 33.4, 36.0),     # Dead Sea and the Jordan valley
    (36.0, 45.0, 48.0, 56.0),     # Caspian Sea and its shores
    (39.0, 50.0, 46.0, 58.0),     # Karagiye and the Turan depressions
    (35.8, -117.6, 36.8, -116.4), # Death Valley
    (32.4, -116.5, 33.8, -115.2), # Salton Sea and the Imperial Valley
    (28.5, 25.5, 30.8, 29.5),     # Qattara and Siwa
    (11.0, 39.5, 15.0, 42.5),     # Danakil and Lake Assal
    (42.3, 88.5, 43.3, 90.0),     # Turpan
    (-30.5, 136.0, -27.5, 139.0), # Lake Eyre
]


def download(directory):
    os.makedirs(directory, exist_ok=True)
    page = subprocess.run(["curl", "-sSfL", CATALOG], capture_output=True, check=True).stdout.decode()
    names = sorted(set(re.findall(r"ETOPO_2022_v1_15s_[NS]\d\d[EW]\d\d\d_surface\.nc", page)))
    print(f"{len(names)} ETOPO files", file=sys.stderr)

    def get(name):
        path = os.path.join(directory, name)
        if os.path.exists(path):
            return
        subprocess.run(["curl", "-sSfL", "--retry", "5", "-o", path + ".part", FILES + name], check=True)
        os.replace(path + ".part", path)

    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        list(pool.map(get, names))


def col_factor(south):
    """How many times coarser columns are than rows, by latitude (as Copernicus does)."""
    lat = abs(south + 0.5)
    return 1 if lat < 50 else 1.5 if lat < 60 else 2 if lat < 70 else 3 if lat < 80 else 5 if lat < 85 else 10


DIVISORS = [d for d in range(1, SOURCE + 1) if SOURCE % d == 0]


def cols_for(rows, south):
    return max(d for d in DIVISORS if d <= max(1, round(rows / col_factor(south))))


def keep_below_sea(south, west):
    return any(s < south + 1 and south < n and w < west + 1 and west < e for s, w, n, e in DEPRESSIONS)


def encode(values):
    """zlib of the planar-prediction residuals of an integer grid (see the file layout)."""
    q = values.astype(np.int64)
    p = np.zeros_like(q)
    p[1:, 1:] = q[1:, :-1] + q[:-1, 1:] - q[:-1, :-1]
    p[0, 1:] = q[0, :-1]
    p[1:, 0] = q[:-1, 0]
    r = q - p
    z = np.where(r >= 0, 2 * r, -2 * r - 1)
    assert z.max() < 65536
    z = z.astype(np.uint16).ravel()
    planes = np.concatenate([(z & 255).astype(np.uint8), (z >> 8).astype(np.uint8)])
    return zlib.compress(planes.tobytes(), 9)


def upsample(coarse, kr, kc):
    """Bilinear back onto the source pixels, as PeakCore interpolates."""
    R, C = coarse.shape
    rows = (np.arange(R * kr) + 0.5) / kr - 0.5
    cols = (np.arange(C * kc) + 0.5) / kc - 0.5
    r0 = np.clip(np.floor(rows).astype(int), 0, R - 1)
    c0 = np.clip(np.floor(cols).astype(int), 0, C - 1)
    r1, c1 = np.minimum(r0 + 1, R - 1), np.minimum(c0 + 1, C - 1)
    fr, fc = np.clip(rows - r0, 0, 1)[:, None], np.clip(cols - c0, 0, 1)
    a = coarse[np.ix_(r0, c0)] * (1 - fc) + coarse[np.ix_(r0, c1)] * fc
    b = coarse[np.ix_(r1, c0)] * (1 - fc) + coarse[np.ix_(r1, c1)] * fc
    return a * (1 - fr) + b * fr


def process_file(args):
    """Every 1° cell of one 15° ETOPO file at every level: (south, west, [(rows, cols, rmse, blob)])."""
    path, step, ridge = args
    import h5py
    m = re.search(r"_([NS])(\d\d)([EW])(\d\d\d)_", os.path.basename(path))
    north = int(m.group(2)) * (1 if m.group(1) == "N" else -1)
    west0 = int(m.group(4)) * (1 if m.group(3) == "E" else -1)
    with h5py.File(path, "r") as f:
        z = f["z"][:].astype(np.float64)[::-1]   # rows from the north
    z[~np.isfinite(z) | (z < -1e4)] = 0
    cells = []
    for i in range(z.shape[0] // SOURCE):
        south = north - 1 - i
        for j in range(z.shape[1] // SOURCE):
            west = west0 + j
            cell = z[i * SOURCE:(i + 1) * SOURCE, j * SOURCE:(j + 1) * SOURCE]
            if not keep_below_sea(south, west):
                cell = np.maximum(cell, 0)
            if not np.any(cell != 0):
                cells.append((south, west, []))
                continue
            levels = []
            for rows in LEVELS:
                cols = cols_for(rows, south)
                kr, kc = SOURCE // rows, SOURCE // cols
                blocks = cell.reshape(rows, kr, cols, kc)
                mean = blocks.mean(axis=(1, 3))
                # Pulled toward each block's top, so ridges and summits don't sink.
                agg = mean + ridge * (blocks.max(axis=(1, 3)) - mean)
                values = np.rint(agg / step)
                # How much detail the level loses, from the means (the maxima's lift is wanted).
                rmse = float(np.sqrt(((upsample(mean, kr, kc) - cell) ** 2).mean()))
                levels.append((rows, cols, rmse, encode(values)))
            cells.append((south, west, levels))
    return cells


def choose(cells, budget, tau=None):
    """The height error allowed so the terrain fits the budget, and each cell's level."""
    def pick(tau):
        out = {}
        for key, levels in cells.items():
            if levels:
                # The coarsest level within tau, else the finest.
                out[key] = next((l for l in reversed(levels) if l[2] <= tau), levels[0])
        return out

    def size(choice):
        return sum(len(l[3]) for l in choice.values())

    if tau is not None:
        return tau, pick(tau)
    lo, hi = 0.0, 2000.0
    for _ in range(40):
        mid = (lo + hi) / 2
        if size(pick(mid)) > budget:
            lo = mid
        else:
            hi = mid
    return hi, pick(hi)


# MARK: Peaks

SPACES = {" ", " ", " ", " "}


def parse_elevation(raw):
    """PeakCore's Overpass.parseElevation, in Python."""
    s = raw.lower().strip()
    for prefix in ["~", "ca.", "ca", "c.", "approx.", "approx", "about"]:
        if s.startswith(prefix):
            s = s[len(prefix):].strip(" ")
            break
    n = 0
    while n < len(s) and ((s[n].isascii() and (s[n].isdigit() or s[n] in ".,")) or s[n] in SPACES):
        n += 1
    number, rest = s[:n], s[n:]
    groups = [g for g in re.split("[" + "".join(SPACES) + "]", number) if g]
    if not groups:
        return None
    first = groups[0]
    grouped = len(groups) > 1 and all(len(g) == 3 and g.isdigit() for g in groups[1:])
    number = "".join(groups) if grouped else first
    unit = rest if grouped or len(groups) == 1 else s[len(first):]
    feet = any(u in unit for u in ["ft", "feet", "foot", "'"])
    comma, dot = number.rfind(","), number.rfind(".")
    if comma >= 0 and dot >= 0:
        number = (number.replace(".", "").replace(",", ".") if comma > dot else number.replace(",", ""))
    elif comma >= 0:
        number = number.replace(",", "") if len(number) - comma - 1 == 3 else number.replace(",", ".")
    try:
        v = float(number)
    except ValueError:
        return None
    if not (0 < v < 9000 * (3.3 if feet else 1)):
        return None
    return v * 0.3048 if feet else v


def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_peaks(path):
    peaks = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
            try:
                pid, lat, lon = int(parts[0]), float(parts[1]), float(parts[2])
            except ValueError:
                continue
            name = parts[3].strip().replace("\0", "")
            if not name or not (-90 <= lat <= 90 and -180 <= lon <= 180):
                continue
            ele = parse_elevation(parts[4]) if parts[4] else None
            prom = parse_elevation(parts[5]) if parts[5] else None
            m = re.fullmatch(r"Q(\d+)", parts[6].strip())
            peaks[pid] = (lat, lon, ele, prom, int(m.group(1)) if m else 0, name)
    return peaks


def peak_blocks(peaks):
    blocks = [[] for _ in range(36 * 72)]
    for pid, (lat, lon, *_rest) in peaks.items():
        bi = min(35, int((lat + 90) // 5)) * 72 + min(71, int((lon + 180) // 5))
        blocks[bi].append(pid)
    out = []
    for bi, ids in enumerate(blocks):
        if not ids:
            out.append(b"")
            continue
        ids.sort()
        south, west = (bi // 72) * 5 - 90, (bi % 72) * 5 - 180
        idcol, lat, lon, ele, prom, wd, names = bytearray(), bytearray(), bytearray(), bytearray(), bytearray(), bytearray(), bytearray()
        last = 0
        for pid in ids:
            p = peaks[pid]
            idcol += varint(pid - last)
            last = pid
            lat += min(500_000, max(0, round((p[0] - south) * 1e5))).to_bytes(3, "little")
            lon += min(500_000, max(0, round((p[1] - west) * 1e5))).to_bytes(3, "little")
            ele += struct.pack("<h", -32768 if p[2] is None else max(-32767, min(32767, round(p[2]))))
            prom += struct.pack("<H", 0 if p[3] is None else max(1, min(65535, round(p[3]))))
            wd += varint(p[4])
            names += p[5].encode("utf-8") + b"\0"
        out.append(zlib.compress(struct.pack("<I", len(ids)) + bytes(idcol + lat + lon + ele + prom + wd + names), 9))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--etopo", help="directory of ETOPO 2022 15″ surface files")
    ap.add_argument("--download", action="store_true", help="download the ETOPO files that are missing first")
    ap.add_argument("--peaks", help="tab-separated peaks from fetch_world_peaks.py")
    ap.add_argument("--out", required=True)
    ap.add_argument("--terrain-mb", type=float, default=36, help="size the terrain may take, MB")
    ap.add_argument("--step", type=float, default=4, help="height step, meters")
    ap.add_argument("--ridge", type=float, default=1.0,
                    help="0: block means; 1: block maxima; between: that share of the way from mean to max")
    ap.add_argument("--max-error", type=float,
                    help="height error allowed per cell, m RMS, instead of fitting --terrain-mb")
    ap.add_argument("--region", type=float, nargs=4, metavar=("S", "W", "N", "E"),
                    help="only these cells (for tests); the rest of the world is left out")
    ap.add_argument("--fixture", action="store_true", help="write the tests' small fixture to --out instead")
    args = ap.parse_args()
    if args.fixture:
        return fixture(args.out)
    if not args.etopo or not args.peaks:
        ap.error("--etopo and --peaks are needed")

    if args.download:
        download(args.etopo)
    files = sorted(os.path.join(args.etopo, f) for f in os.listdir(args.etopo) if f.endswith("_surface.nc"))
    if args.region:
        s, w, n, e = args.region

        def touches(f):
            m = re.search(r"_([NS])(\d\d)([EW])(\d\d\d)_", f)
            north = int(m.group(2)) * (1 if m.group(1) == "N" else -1)
            west = int(m.group(4)) * (1 if m.group(3) == "E" else -1)
            return north - 15 < n and s < north and west < e and w < west + 15
        files = [f for f in files if touches(f)]
    if not args.region and len(files) != 288:
        sys.exit(f"expected 288 ETOPO files in {args.etopo}, found {len(files)} (use --download)")

    cells = {}
    with concurrent.futures.ProcessPoolExecutor() as pool:
        for found in pool.map(process_file, [(f, args.step, args.ridge) for f in files]):
            for south, west, levels in found:
                if args.region and not (s <= south < n and w <= west < e):
                    continue
                cells[(south, west)] = levels
    tau, choice = choose(cells, args.terrain_mb * 1e6, args.max_error)
    counts = {rows: sum(1 for l in choice.values() if l[0] == rows) for rows in LEVELS}
    print(f"terrain: height error up to {tau:.1f} m RMS per cell; cells by rows per degree: {counts}", file=sys.stderr)

    peaks = read_peaks(args.peaks)
    if args.region:
        peaks = {k: p for k, p in peaks.items() if s <= p[0] < n and w <= p[1] < e}
    write(args.out, args.step, {k: (l[0], l[1], l[3]) for k, l in choice.items()}, peaks)


def write(out, step, cells, peaks):
    """Writes the file: `cells` maps (south, west) to (rows, cols, encoded heights)."""
    index, data = bytearray(), bytearray()
    for south in range(-90, 90):
        for west in range(-180, 180):
            cell = cells.get((south, west))
            if cell:
                data += cell[2]
                index += struct.pack("<BBI", cell[0], cell[1], len(data))
            else:
                index += struct.pack("<BBI", 0, 0, len(data))
    blocks = peak_blocks(peaks)
    peak_index, peak_data = bytearray(), bytearray()
    for b in blocks:
        peak_data += b
        peak_index += struct.pack("<I", len(peak_data))

    t_index = 64
    t_data = t_index + len(index)
    p_index = t_data + len(data)
    p_data = p_index + len(peak_index)
    header = MAGIC + struct.pack("<IfIQQQQ", VERSION, step, len(peaks), t_index, t_data, p_index, p_data)
    header += b"\0" * (64 - len(header))
    with open(out + ".part", "wb") as f:
        f.write(header + index + data + peak_index + peak_data)
    os.replace(out + ".part", out)
    total = os.path.getsize(out)
    print(f"{out}: {total / 1e6:.1f} MB (terrain {len(data) / 1e6:.1f} MB, index {len(index) / 1e6:.2f} MB, "
          f"{len(peaks)} peaks {(len(peak_data) + len(peak_index)) / 1e6:.1f} MB)")


def fixture(out):
    """The small file PeakCore's tests read (BaseLayerTests): two cells and three peaks.
    Cell 45°N 7°E is 4 × 4 with value(r, c) = 125 + 6r − 4c + (r·c mod 3), cell 46°N 7°E
    2 × 1 with values 300 and 301, both in 4 m steps; the rest of the world is sea."""
    a = np.array([[125 + 6 * r - 4 * c + (r * c) % 3 for c in range(4)] for r in range(4)])
    b = np.array([[300], [301]])
    peaks = {
        26863664: (45.976426, 7.658602, 4478.0, 1038.0, 1374, "Matterhorn"),
        26863665: (45.5, 7.25, None, None, 0, "Pointe sans nom ü"),
        27000000: (-33.9625, 18.40389, 1085.0, None, 0, "Table Mountain"),
    }
    write(out, 4.0, {(45, 7): (4, 4, encode(a)), (46, 7): (2, 1, encode(b))}, peaks)

if __name__ == "__main__":
    main()
