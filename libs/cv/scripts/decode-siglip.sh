#!/usr/bin/env bash
# decode-siglip.sh SRC DST.ppm: the 224x224 RGB picture SigLIP sees: first frame, squashed (no crop), Catmull-Rom with antialiasing
# (PIL BICUBIC's kernel), alpha dropped as PIL convert("RGB") does. libvips; ImageMagick when vips fails or writes anything but P6.
set -euo pipefail
src=$1 dst=$2
if vips thumbnail "$src" "$dst" 224 --height 224 --size force --kernel cubic --no-rotate 2>/dev/null && [ "$(head -c 2 "$dst")" = P6 ]; then exit 0; fi
magick "${src}[0]" -alpha off -colorspace sRGB -filter Catrom -resize '224x224!' -depth 8 "ppm:$dst"
