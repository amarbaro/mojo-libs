#!/usr/bin/env bash
# Tests the baseline decoder against TJ3 and exercises its rejection path.
set -euo pipefail
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
scope() { systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 "$@"; }
[ "$#" = 1 ] || fail usage 'jpeg_baseline.sh PLANTED_JPEG_DIR (created by tests/stock_planted.sh)'
planted=$(realpath -e -- "$1") || fail setup 'planted fixture directory missing'
cd "$(dirname "$0")/.."
for f in plain rot6 cmyk scrgb; do
  [ -s "$planted/$f.jpg" ] || fail setup "missing planted fixture $f.jpg"
done
mkdir -p .work
work=$(mktemp -d .work/jpeg-baseline.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
scope timeout 20 "${MOJO:-mojo}" build -O3 -I src tests/jpeg_baseline.mojo -o "$work/check" || fail build 'Mojo oracle'
for size in 1x1 3x5 17x9 49x37 127x111; do
  scope magick -seed 301 -size "$size" plasma:fractal -depth 8 -strip "$work/source.ppm" || fail fixture "$size"
  for samp in 1x1 2x1 2x2; do
    scope cjpeg -quality 96 -sample "$samp,1x1,1x1" -outfile "$work/$size-$samp.jpg" "$work/source.ppm" || fail fixture "$size $samp"
    scope cjpeg -quality 96 -optimize -sample "$samp,1x1,1x1" -restart 2B -outfile "$work/$size-$samp-rst.jpg" "$work/source.ppm" || fail fixture "$size $samp restart"
  done
  scope cjpeg -grayscale -restart 1B -outfile "$work/$size-gray.jpg" "$work/source.ppm" || fail fixture "$size gray"
  scope cjpeg -rgb -outfile "$work/$size-rgb.jpg" "$work/source.ppm" || fail fixture "$size RGB"
done
printf '0: 0 63 0 0; 1 2: 0 63 0 0;\n' > "$work/scans"
scope cjpeg -scans "$work/scans" -restart 3B -outfile "$work/multiscan.jpg" "$work/source.ppm" || fail fixture 'sequential scans'
scope timeout 20 "$work/check" parity "$planted/plain.jpg" "$work"/*.jpg || fail parity 'TurboJPEG ISLOW comparison'
scope cjpeg -progressive -outfile "$work/prog.jpg" "$work/source.ppm" || fail fixture progressive
scope cjpeg -arithmetic -outfile "$work/arith.jpg" "$work/source.ppm" || fail fixture arithmetic
scope cjpeg -precision 12 -outfile "$work/12bit.jpg" "$work/source.ppm" || fail fixture 12-bit
scope cjpeg -sample 1x2,1x1,1x1 -outfile "$work/440.jpg" "$work/source.ppm" || fail fixture 4:4:0
for file in "$planted"/{rot6,cmyk,scrgb}.jpg "$work"/{prog,arith,12bit,440}.jpg; do
  scope timeout 20 "$work/check" unsupported "$file" || fail fallback "${file##*/}"
done
scope djpeg -verbose "$work/49x37-2x2-rst.jpg" > /dev/null 2>"$work/markers"
grep -q 'Define Restart Interval 2' "$work/markers" || fail fixture 'missing restart interval'
for path in "$work"/127x111-{2x1,2x2-rst,gray}.jpg "$work"/multiscan.jpg; do
  n=$(wc -c < "$path")
  for cut in 0 1 2 4 32 150 "$((n / 2))" "$((n - 2))" "$((n - 1))"; do
    head -c "$cut" "$path" > "$work/cut.jpg"
    scope timeout 20 "$work/check" corrupt "$work/cut.jpg" || fail corrupt "${path##*/} at byte $cut"
  done
done
printf 'garbage\x00\xff\x00\xfe\x80\xd8' > "$work/garbage.jpg"
scope timeout 20 "$work/check" corrupt "$work/garbage.jpg" || fail corrupt 'garbage input'
printf 'PASS fallback 7 variants\nPASS corrupt 37 files (20 s per file)\n'
