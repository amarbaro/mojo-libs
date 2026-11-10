#!/usr/bin/env bash
# Stage 4 gate (AV1 intra tile parse): tests/av1tile_info.mojo parses every tile of every fixture (primary and alpha items).
# Each tile must end its symbol decoder exactly at the tile end (exit_process, spec 8.2.4) with blocks covering every 4x4 unit.
# The feature totals show which syntax paths the fixtures reached; a path at 0 is printed as UNTESTED, never counted as passed.
# Fixtures: the six stage 1 files plus tests/avif_fixtures.sh (tiles, big, seg.obu). MUTANTS=0 skips the mutants.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/av1tile; mkdir -p $W
build() { timeout 300 "$M" build -I "$1" tests/av1tile_info.mojo -o "$2" 2> "$2.log" || { grep -A6 -m3 error "$2.log" | cut -c1-240; echo "FAIL build: $2"; exit 1; }; }
run_all() {  # $1 binary; prints per-tile lines to $2, returns the number of failing files
  local fails=0; : > "$2"
  for f in $F/*.avif $F/*.obu; do
    if timeout 30 "$1" "$f" > $W/one.out 2>&1; then sed "s|^|$(basename $f) |" $W/one.out >> "$2"
    else echo "FAIL $(basename $f): $(grep -m1 -iE 'error|exception' $W/one.out | cut -c1-200)" >> "$2"; fails=$((fails + 1)); fi
  done
  return $fails
}
build src $W/info
if run_all $W/info $W/tiles.txt; then rc=0; else rc=$?; fi
cat $W/tiles.txt
for k in nonzero skip intrabc palette cfl filter_intra; do
  n=$(awk -v k=$k '{for (i = 1; i < NF; i++) if ($i == k) s += $(i + 1)} END{print s + 0}' $W/tiles.txt)
  [ "$n" -gt 0 ] && echo "covered $k $n" || echo "UNTESTED $k: no fixture block reached it"
done
[ $rc = 0 ] || { echo "FAIL av1tile: $rc files"; exit 1; }
echo "PASS av1tile $(grep -c ' ok ' $W/tiles.txt) tiles"
