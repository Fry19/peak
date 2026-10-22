#!/bin/sh
# Downloads the worldwide base layer (World.pkbase, 47 MB) into Peak/Resources, where the
# app build picks it up. It lives on a GitHub Release rather than in git; the checksum
# below pins the exact file. Without it the app still builds and runs, just without the
# base layer (no view on first launch without a signal).
#
#     sh Tools/fetch_base_layer.sh
#
# To publish a new one: build it with Tools/build_base_layer.py (see the README), upload it
# to a new release, and update TAG and SHA256 here.
set -eu

TAG="base-layer-2026-10"
SHA256="f78f34df69de65729c16aeb4ece47c7195f0ca7eb471a259df01f3858581232e"
URL="https://github.com/Fry19/peak/releases/download/$TAG/World.pkbase"

cd "$(dirname "$0")/.."
OUT="Peak/Resources/World.pkbase"

sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$OUT" ] && [ "$(sum "$OUT")" = "$SHA256" ]; then
    echo "$OUT is up to date ($TAG)"
    exit 0
fi
mkdir -p "$(dirname "$OUT")"
echo "Downloading $URL"
curl -fL --retry 3 -o "$OUT.part" "$URL"
GOT="$(sum "$OUT.part")"
if [ "$GOT" != "$SHA256" ]; then
    rm -f "$OUT.part"
    echo "Checksum mismatch: expected $SHA256, got $GOT" >&2
    exit 1
fi
mv "$OUT.part" "$OUT"
echo "Wrote $OUT ($TAG)"
