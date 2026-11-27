#!/usr/bin/env bash
# Build the current CV CLI and compare mcv-stockcheck with the TurboJPEG baseline.
set -euo pipefail
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
[ "$#" = 2 ] || fail usage 'jpeg_stock.sh LIST REFERENCE_JSONL'
list=$(realpath -e -- "$1") || fail input 'image list missing'
reference=$(realpath -e -- "$2") || fail input 'reference JSONL missing'
cd "$(dirname "$0")/.."
scope() { systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 "$@"; }
[ "$(awk 'NF {n++} END {print n}' "$list")" = 406 ] || fail input 'expected the original 406-image list'
[ "$(jq -n 'reduce inputs as $line (0; . + (if $line.file then 1 else 0 end))' "$reference")" = 406 ] ||
  fail input 'expected 406 image results from the current stockBatch'
mkdir -p .work
work=$(mktemp -d .work/jpeg-stock.XXXXXX)
if [ "${JPEG_KEEP_WORK:-0}" != 1 ]; then
  trap 'rm -rf -- "$work"' EXIT
fi
cp -a scripts "$work/" || fail setup 'copy CV scripts'
mkdir -p "$work/.bin"
scope timeout 90 "${MOJO:-mojo}" build -O3 -I src src/main.mojo -o "$work/.bin/mojo-cv" > "$work/build.log" 2>&1 ||
  { tail -n 6 "$work/build.log" >&2; fail build 'candidate stockBatch'; }
scope timeout 180 "$work/scripts/mcv-stockcheck" -j 14 "$work/candidate.jsonl" "@$list" > "$work/stock.log" 2>&1 ||
  fail stock 'candidate mcv-stockcheck -j 14'
cmp -s "$reference" "$work/candidate.jsonl" ||
  fail stock 'result lines differ from the current stockBatch'
printf 'PASS stock 406 images, byte-identical output\n'
