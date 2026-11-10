#!/usr/bin/env bash
# WebP fixtures and goldens for tests/webp_test.mojo. ImageMagick (libwebp) is the oracle: it encodes the .webp files from the
# style assets and decodes them to FILE.rgba (8-bit RGBA, the golden). Nothing here runs at decode time.
# usage: tests/webp_fixtures.sh  -> .work/webp/*.webp + *.rgba
set -euo pipefail
cd "$(dirname "$0")/.."
command -v magick >/dev/null || { echo "FAIL setup: magick not installed"; exit 1; }
magick -list format | grep -q 'WEBP\*' || { echo "FAIL setup: magick has no WebP support"; exit 1; }
D=.work/webp
rm -rf "$D" && mkdir -p "$D"
BG=assets/styles/bauhaus/bg.jpg
IC=assets/styles/bauhaus/icons/bell.png
IC2=assets/styles/neon/icons/home.png
[ -f "$IC2" ] || IC2=assets/styles/bauhaus/icons/home.png
# enc NAME SRC [magick options...]: encode, then decode with libwebp for the golden
enc() {
  local n=$1 src=$2; shift 2
  magick "$src" "$@" "$D/$n.webp" || { echo "FAIL fixture: $n"; exit 1; }
  magick "$D/$n.webp" -depth 8 "rgba:$D/$n.rgba" || { echo "FAIL golden: $n"; exit 1; }
}
SMALL=(-resize 160x90!)
# lossless: whole 1280x720 background, small crops, icons with alpha, a 4-colour palette, a 2-colour palette
enc ll_bg "$BG" -define webp:lossless=true -define webp:method=4
enc ll_bg_small "$BG" "${SMALL[@]}" -define webp:lossless=true -define webp:method=6
enc ll_icon "$IC" -define webp:lossless=true
enc ll_icon2 "$IC2" -define webp:lossless=true -define webp:method=6
enc ll_icon_exact "$IC" -define webp:lossless=true -define webp:exact=true
enc ll_pal4 "$BG" "${SMALL[@]}" -colors 4 -dither None -define webp:lossless=true -define webp:method=6
enc ll_pal2 "$IC" -colors 2 -dither None -define webp:lossless=true -define webp:method=6
enc ll_pal16 "$BG" "${SMALL[@]}" -colors 16 -dither None -define webp:lossless=true -define webp:method=6
enc ll_noise "$BG" -resize 97x53! -attenuate 0.6 +noise Gaussian -define webp:lossless=true -define webp:method=6
enc ll_tiny "$IC" -resize 1x1! -define webp:lossless=true
enc ll_odd "$BG" -resize 37x23! -define webp:lossless=true -define webp:method=6
# lossy VP8, no alpha
enc ly_bg "$BG" -quality 75 -define webp:method=4
enc ly_bg_q30 "$BG" -quality 30 -define webp:method=4
enc ly_bg_small "$BG" "${SMALL[@]}" -quality 75 -define webp:method=6
enc ly_bg_odd "$BG" -resize 37x23! -quality 75
enc ly_bg_sharp "$BG" "${SMALL[@]}" -quality 90 -define webp:sharp-yuv=true -define webp:filter-strength=0
enc ly_bg_seg "$BG" "${SMALL[@]}" -quality 60 -define webp:segments=4 -define webp:partitions=3 -define webp:filter-sharpness=4
enc ly_bg_simple "$BG" "${SMALL[@]}" -quality 75 -define webp:filter-type=0
# lossy with alpha: raw and lossless-compressed alpha, every filter
enc ly_alpha_raw "$IC" -quality 75 -define webp:alpha-compression=0 -define webp:alpha-filtering=0
enc ly_alpha_ll "$IC" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=0
enc ly_alpha_fast "$IC" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=1
enc ly_alpha_best "$IC2" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=2
enc ly_alpha_bg "$BG" "${SMALL[@]}" -alpha set -channel A -evaluate set 60% +channel -quality 75
ls "$D"/*.webp | wc -l | xargs echo "PASS webp_fixtures files:"
