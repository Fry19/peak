#!/usr/bin/env python3
"""Download every named OpenStreetMap peak and volcano in the world, for the base layer.

Asks QLever's SPARQL endpoint for the OpenStreetMap planet (University of Freiburg, updated
about weekly), which answers this in under a minute; the Overpass API times out on a
query this big. Then asks QLever's copy of Wikidata for every item's prominence (P2660),
picked as the app picks it (PeakCore's `Wikidata.prominence(of:)`): Wikidata's conversion
to meters, a preferred statement over normal ones, the highest of one rank, 0–9000 m,
deprecated ones left out. The result is one tab-separated file, ordered by id:
id, lat, lon, name, ele, prominence, wikidata (the raw OSM values), then the prominence
Wikidata gives that item in meters (empty when none, or when the tag isn't one item id).

    python3 Tools/fetch_world_peaks.py --out build/world_peaks.tsv

Data © OpenStreetMap contributors, under the ODbL; Wikidata, CC0.
"""

import argparse
import os
import re
import subprocess
import sys

ENDPOINT = "https://qlever.dev/api/osm-planet"
WIKIDATA = "https://qlever.dev/api/wikidata"
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

# PeakCore's `Wikidata.prominenceQuery`, for every item rather than a list of them.
PROMINENCE = """PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psn: <http://www.wikidata.org/prop/statement/value-normalized/>
PREFIX wikibase: <http://wikiba.se/ontology#>
SELECT ?item ?rank ?amount WHERE {
  ?item p:P2660 ?statement .
  ?statement wikibase:rank ?rank ; psn:P2660 ?value .
  ?value wikibase:quantityAmount ?amount ; wikibase:quantityUnit wd:Q11573 .
}"""


def literal(term):
    """The text of a SPARQL TSV literal ("…", maybe with a language or type), or ''."""
    if not term.startswith('"'):
        return ""
    text = term[1:term.rfind('"')]
    return re.sub(r'\\(.)', lambda m: {"t": " ", "n": " ", "r": " "}.get(m.group(1), m.group(1)), text)


def sparql(endpoint, query, first):
    """The rows of a SPARQL TSV answer, after its header (which starts with `first`)."""
    r = subprocess.run(["curl", "-sSL", "--fail", "--post301", "--post302", "--max-time", "1200",
                        "-A", USER_AGENT, "-H", "Accept: text/tab-separated-values",
                        "--data-urlencode", "query@-", endpoint],
                       input=query.encode(), capture_output=True)
    if r.returncode != 0:
        sys.exit(f"QLever: {r.stderr.decode(errors='replace').strip()}")
    lines = r.stdout.decode("utf-8").splitlines()
    if not lines or not lines[0].startswith(first):
        sys.exit(f"QLever: unexpected answer: {lines[:1]}")
    return lines[1:]


def fetch(tag):
    lines = sparql(ENDPOINT, QUERY % tag, "?node")
    rows = {}
    for line in lines:
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


def prominence(statements):
    """PeakCore's `Wikidata.prominence(of:)`: of (preferred, meters), values no summit could
    have left out, a preferred one wins over normal ones, and of one rank the highest."""
    valid = [s for s in statements if 0 <= s[1] <= 9000]
    best = [s for s in valid if s[0]] or valid
    return max((s[1] for s in best), default=None)


def fetch_prominence():
    """Prominence by Wikidata item id ("Q1374"), meters."""
    statements = {}
    for line in sparql(WIKIDATA, PROMINENCE, "?item"):
        cols = (line.split("\t") + [""] * 3)[:3]
        item = re.fullmatch(r"<http://www\.wikidata\.org/entity/(Q[0-9]{1,12})>", cols[0])
        rank = {"<http://wikiba.se/ontology#PreferredRank>": True,
                "<http://wikiba.se/ontology#NormalRank>": False}.get(cols[1])
        try:
            meters = float(literal(cols[2]) if cols[2].startswith('"') else cols[2])
        except ValueError:
            continue
        if item and rank is not None:
            statements.setdefault(item.group(1), []).append((rank, meters))
    table = {k: m for k, v in statements.items() if (m := prominence(v)) is not None}
    print(f"{len(table)} Wikidata items with a prominence", file=sys.stderr)
    return table


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="tab-separated output file")
    args = ap.parse_args()
    rows = fetch("peak")
    rows.update(fetch("volcano"))
    table = fetch_prominence()
    for row in rows.values():
        meters = table.get(row[6].strip())   # nothing for a tag like "Q1;Q2"
        row.append("" if meters is None else repr(meters))
    print(f"{sum(1 for r in rows.values() if r[7])} peaks with Wikidata's prominence, "
          f"{sum(1 for r in rows.values() if r[7] and not r[5])} of them without OpenStreetMap's", file=sys.stderr)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out + ".part", "w", encoding="utf-8") as f:
        for k in sorted(rows):
            f.write("\t".join(rows[k]) + "\n")
    os.replace(args.out + ".part", args.out)
    print(f"{len(rows)} peaks in {args.out}")


if __name__ == "__main__":
    main()
