#!/usr/bin/env bash
# JPEG speed gate (CPU, one core): imkit Jpeg (parse, idct, rgb) against djpeg -dct int on the same files, same core.
# The RGB bytes of each file must hash equal (FNV-1a 64) to djpeg's PPM pixel data; exit 0 only when all match.
# usage: tests/jpeg_speed.sh LIST   LIST: one JPEG path per line (read-only inputs, never written)
#        JPEG_CORE=N pins another core (default 2); MOJO=path picks the mojo binary
set -euo pipefail
cd "$(dirname "$0")/.."
LIST=${1:?"FAIL usage: tests/jpeg_speed.sh LIST"}
[ -r "$LIST" ] || { echo "FAIL input: $LIST not readable"; exit 1; }
M=${MOJO:-mojo}
CORE=${JPEG_CORE:-2}
command -v djpeg >/dev/null || { echo "FAIL setup: djpeg (libjpeg-turbo oracle) not installed"; exit 1; }
command -v taskset >/dev/null || { echo "FAIL setup: taskset not installed"; exit 1; }
W=.work/jpeg_speed
rm -rf "$W" && mkdir -p "$W"
mapfile -t F < <(awk 'NF' "$LIST")
[ "${#F[@]}" -gt 0 ] || { echo "FAIL input: no paths in $LIST"; exit 1; }
for f in "${F[@]}"; do [ -r "$f" ] || { echo "FAIL input: $f not readable"; exit 1; }; done
$M build -O3 -I src tests/jpeg_speed.mojo -o "$W/jpeg_speed" 2>"$W/build.err" || { echo "FAIL build: tests/jpeg_speed.mojo"; grep -A3 error "$W/build.err" | head -40; exit 1; }
# oracle output, not timed: libjpeg-turbo int IDCT to PPM, hashed by the same driver
PPM=()
for i in "${!F[@]}"; do
  djpeg -dct int -ppm "${F[$i]}" > "$W/$i.ppm" || { echo "FAIL oracle: djpeg ${F[$i]}"; exit 1; }
  PPM+=("$W/$i.ppm")
done
"$W/jpeg_speed" hash-ppm "${PPM[@]}" > "$W/oracle.hash" || { echo "FAIL oracle: hash-ppm"; exit 1; }
rm -f "${PPM[@]}"
# imkit: timed inside the driver, pinned to one core
taskset -c "$CORE" "$W/jpeg_speed" "${F[@]}" > "$W/imkit.txt" || { echo "FAIL imkit: decode"; exit 1; }
# djpeg: wall time per file on the same core, output to /dev/null
: > "$W/djpeg.ns"
for f in "${F[@]}"; do
  t0=$(date +%s%N)
  taskset -c "$CORE" djpeg -dct int -ppm "$f" > /dev/null || { echo "FAIL djpeg: $f"; exit 1; }
  t1=$(date +%s%N)
  echo $((t1 - t0)) >> "$W/djpeg.ns"
done
# per-file hash comparison: a missing line is a failure, never a pass
awk '$1 != "MEAN" { sub(/^fnv=/, "", $NF); print $NF }' "$W/imkit.txt" > "$W/imkit.hash"
N=$(wc -l < "$W/imkit.hash")
[ "$N" -eq "${#F[@]}" ] || { echo "FAIL hash: $N imkit lines for ${#F[@]} files"; exit 1; }
[ "$(wc -l < "$W/oracle.hash")" -eq "$N" ] || { echo "FAIL hash: oracle lines differ from imkit lines"; exit 1; }
paste -d' ' "$W/imkit.hash" "$W/oracle.hash" > "$W/pairs.txt"
BAD=$(awk '$1 != $2 { b++ } END { print b + 0 }' "$W/pairs.txt")
if [ "$BAD" -ne 0 ]; then
  awk '$1 != $2 { print "  mismatch line " NR ": imkit " $1 " djpeg " $2 }' "$W/pairs.txt"
  echo "FAIL hash: $BAD of $N files differ from djpeg"
  exit 1
fi
# means and the speed ratio
MEAN=$(awk '$1 == "MEAN"' "$W/imkit.txt")
PARSE=$(echo "$MEAN" | awk '{ print $2 }')
IDCT=$(echo "$MEAN" | awk '{ print $3 }')
RGB=$(echo "$MEAN" | awk '{ print $4 }')
TOT=$(echo "$MEAN" | awk '{ print $5 }')
DJ=$(awk '{ s += $1 } END { printf "%.1f", s / NR / 1e6 }' "$W/djpeg.ns")
RATIO=$(awk -v a="$TOT" -v b="$DJ" 'BEGIN { printf "%.1f", a / b }')
echo "stage (mean of $N files, core $CORE)  ms"
echo "parse+huffman                      $PARSE"
echo "idct                               $IDCT"
echo "up+rgb                             $RGB"
echo "imkit total                        $TOT"
echo "djpeg -dct int (wall, /dev/null)   $DJ"
echo "ratio imkit total / djpeg          ${RATIO}x"
echo "PASS jpeg_speed: $N of $N hashes match djpeg"
