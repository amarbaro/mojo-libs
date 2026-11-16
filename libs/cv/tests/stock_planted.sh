#!/usr/bin/env bash
# tests/stock_planted.sh: the planted failures (tools/oracle_cv2.py fixtures) go through scripts/mcv-stockcheck and
# each must raise exactly its own flags (lowres and duplicate aside); clean images raise none; twins of one scene
# pair up and unrelated pictures do not. Thresholds are the defaults of docs/stockcheck.md.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f tests/fixtures/stock/hd.png ] || .venv/bin/python -I tools/oracle_cv2.py --fixtures tests/fixtures
[ -x .bin/mojo-cv ] || { echo "FAIL setup: .bin/mojo-cv missing"; exit 1; }
mkdir -p .work
out=.work/stock_planted.jsonl
scripts/mcv-stockcheck "$out" tests/fixtures/stock/*.png > .work/stock_planted.log || { cat .work/stock_planted.log; echo "FAIL stock_planted: scripts/mcv-stockcheck"; exit 1; }
fail=0
check() {  # name expected-flags
  got=$(jq -r --arg n "$1.png" 'select(.file and (.file|endswith("/"+$n))) | .flags | map(select(. != "lowres" and . != "duplicate")) | sort | join(" ")' "$out")
  [ "$got" = "$2" ] && echo "PASS flags $1: [$got]" || { echo "FAIL flags $1: got [$got] want [$2]"; fail=1; }
}
check hd ""; check hd2 ""; check st_big ""; check st_jpg95 ""
check st_blur "blur"; check st_noise "noise"; check st_blown "clipHigh"; check st_cast "cast"; check st_fog "flatStrip"
check st_jpg8 "banding blocks"   # heavy JPEG also leaves flat runs with big steps
check st_band "banding blur"     # a banded ramp has no detail either
check st_grad "blur"             # the clean dithered ramp: soft, but not banded
paired() {  # a b want(1|0)
  n=$(jq -s --arg a "$1.png" --arg b "$2.png" '[.[]|select(.dup)|.dup|select((.a|endswith("/"+$a)) and (.b|endswith("/"+$b)) or (.a|endswith("/"+$b)) and (.b|endswith("/"+$a)))]|length' "$out")
  [ "$n" = "$3" ] && echo "PASS dup $1 $2: $n" || { echo "FAIL dup $1 $2: got $n want $3"; fail=1; }
}
paired hd st_jpg95 1; paired hd st_blur 1; paired hd st_noise 1; paired hd st_cast 1; paired hd hd2 1
paired hd st_grad 0; paired st_grad st_band 0; paired hd st_big 1
# the fast decoder (libvips, .ppm) must give the same numbers as the ImageMagick one (.mcv)
four=(tests/fixtures/stock/hd.png tests/fixtures/stock/st_blur.png tests/fixtures/stock/st_noise.png tests/fixtures/stock/st_jpg8.png)
MCV_DECODER=magick scripts/mcv-stockcheck .work/stock_planted_magick.jsonl "${four[@]}" > /dev/null
scripts/mcv-stockcheck .work/stock_planted_vips.jsonl "${four[@]}" > /dev/null
nums() { jq -c 'select(.file) | del(.dupOf, .flags)' "$1" | sort; }
if [ "$(nums .work/stock_planted_magick.jsonl)" = "$(nums .work/stock_planted_vips.jsonl)" ]; then echo "PASS decoders: vips and magick numbers identical on 4 images"; else echo "FAIL decoders: vips and magick numbers differ"; fail=1; fi
[ "$fail" = 0 ] || exit 1
echo "PASS stock_planted"
