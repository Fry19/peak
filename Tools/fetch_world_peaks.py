#!/usr/bin/env python3
"""Download every named OpenStreetMap peak and volcano in the world, for the base layer.

Asks QLever's SPARQL endpoint for the OpenStreetMap planet (University of Freiburg, updated
about weekly), which answers this in under a minute; the Overpass API times out on a
query this big. The result is one tab-separated file, ordered by id:
id, lat, lon, name, ele, prominence, wikidata (the raw OSM values).

    python3 Tools/fetch_world_peaks.py --out build/world_peaks.tsv

Data © OpenStreetMap contributors, under the ODbL.
"""

import argparse
import os
import re
import subprocess
import sys

ENDPOINT = "https://qlever.dev/api/osm-planet"
USER_AGENT = "Peak base-layer build (github.com/Fry19/peak)"

QUERY = """PREFIX osmkey: <https://www.openstreetmap.org/wiki/Key:>
PREFIX osm: <https://www.openstreetmap.org/>
PREFIX geo: <http://www.opengis.net/ont/geosparql#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT ?node ?geom ?name ?ele ?prom ?wd WHERE {
  ?node osmkey:natural "%s" .
  ?node rdf:type osm:node .
  ?node osmkey:name ?name .
  ?node geo:hasGeometry/geo:asWKT ?geom .
  OPTIONAL { ?node osmkey:ele ?ele }
  OPTIONAL { ?node osmkey:prominence ?prom }
  OPTIONAL { ?node osmkey:wikidata ?wd }
}"""


def literal(term):
    """The text of a SPARQL TSV literal ("…", maybe with a language or type), or ''."""
    if not term.startswith('"'):
        return ""
    text = term[1:term.rfind('"')]
    return re.sub(r'\\(.)', lambda m: {"t": " ", "n": " ", "r": " "}.get(m.group(1), m.group(1)), text)


def fetch(tag):
    r = subprocess.run(["curl", "-sSL", "--fail", "--post301", "--post302", "--max-time", "1200",
                        "-A", USER_AGENT, "-H", "Accept: text/tab-separated-values",
                        "--data-urlencode", "query@-", ENDPOINT],
                       input=(QUERY % tag).encode(), capture_output=True)
    if r.returncode != 0:
        sys.exit(f"QLever: {r.stderr.decode(errors='replace').strip()}")
    lines = r.stdout.decode("utf-8").splitlines()
    if not lines or not lines[0].startswith("?node"):
        sys.exit(f"QLever: unexpected answer: {lines[:1]}")
    rows = {}
    for line in lines[1:]:
        cols = (line.split("\t") + [""] * 6)[:6]
        m = re.search(r"/node/(\d+)>", cols[0])
        g = re.match(r'"?POINT\(([-\d.eE]+) ([-\d.eE]+)\)', cols[1])
        if not m or not g:
            continue
        pid = int(m.group(1))
        if pid in rows:
            continue   # a second value of an optional tag
        rows[pid] = [str(pid), g.group(2), g.group(1), literal(cols[2]), literal(cols[3]),
                     literal(cols[4]), literal(cols[5])]
    print(f"{len(rows)} named natural={tag}", file=sys.stderr)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="tab-separated output file")
    args = ap.parse_args()
    rows = fetch("peak")
    rows.update(fetch("volcano"))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out + ".part", "w", encoding="utf-8") as f:
        for k in sorted(rows):
            f.write("\t".join(rows[k]) + "\n")
    os.replace(args.out + ".part", args.out)
    print(f"{len(rows)} peaks in {args.out}")


if __name__ == "__main__":
    main()
