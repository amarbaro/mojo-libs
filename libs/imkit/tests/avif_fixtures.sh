#!/usr/bin/env bash
# Extra fixtures for the tile-parse gates, each made for one bitstream property, which the script then checks in ffmpeg's
# trace_headers (a fixture is checked for the property it exists for): tiles.avif = 2x2 tiles, big.avif = full-size screenshot
# with default tools, seg.obu = raw key frame OBUs from aomenc with segmentation (aq-mode 1; avifenc's all-intra mode never
# enables it). delta_lf_present = 1 was not reachable from avifenc or aomenc, so that path has no fixture.
# The older six (a10 a420 a444 alpha lossless mono .avif) are kept as they are.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; mkdir -p $F
src=docs/img/gallery-glass.png
small=$F/src-320.png
[ -f $small ] || timeout 30 magick $src -resize 320x180! $small
timeout 120 avifenc -q 60 -s 6 --tilecolslog2 1 --tilerowslog2 1 $src -o $F/tiles.avif > /dev/null || { echo "FAIL avifenc: tiles"; exit 1; }
timeout 120 avifenc -q 60 -s 6 $src -o $F/big.avif > /dev/null || { echo "FAIL avifenc: big"; exit 1; }
timeout 30 ffmpeg -v error -y -i $small -pix_fmt yuv420p $F/src-320.y4m
timeout 120 aomenc --limit=1 --kf-max-dist=0 --end-usage=q --cq-level=30 --cpu-used=6 --aq-mode=1 --deltaq-mode=0 \
  -o $F/seg.ivf $F/src-320.y4m > /dev/null 2>&1 || { echo "FAIL aomenc: seg"; exit 1; }
timeout 30 ffmpeg -v error -y -i $F/seg.ivf -c copy -f obu $F/seg.obu
has() { timeout 30 ffmpeg -v trace -i "$F/$1" -c copy -bsf:v trace_headers -f null - 2>&1 | grep -qE "$2" || { echo "FAIL fixture $1: no '$2' in trace_headers"; exit 1; }; }
has tiles.avif 'tile_cols_log2 +[01]+ = 1$'
has tiles.avif 'tile_rows_log2 +[01]+ = 1$'
has seg.obu 'segmentation_enabled +1 = 1$'
echo "PASS avif_fixtures"
