#!/usr/bin/env bash
# decode-stock.sh SRC DSTBASE: writes DSTBASE.ppm (libvips, 3-4x faster than ImageMagick: 8-bit RGB, EXIF orientation
# applied, no embedded profile) or DSTBASE.mcv (img2mcv.sh: alpha, grey, 16-bit and any embedded ICC profile).
# MCV_DECODER=magick forces the ImageMagick path (the oracle of the fast one, tests/stock_planted.sh).
set -euo pipefail
src=$1 base=$2
export VIPS_WARNING=0 VIPS_CONCURRENCY=1
if [ "${MCV_DECODER:-}" != magick ] && h=$(vipsheader "$src" 2>/dev/null) && [[ $h == *"uchar, 3 bands"* ]] \
   && ! vipsheader -f icc-profile-data "$src" >/dev/null 2>&1; then
  vips autorot "$src" "$base.ppm" 2>/dev/null && exit 0
  rm -f "$base.ppm"
fi
exec "$(dirname "$0")/img2mcv.sh" "$src" "$base.mcv" bgr
