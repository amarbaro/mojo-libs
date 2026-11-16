#!/usr/bin/env bash
# tests/stock_faces.sh: the face stage of mcv-stockcheck (--faces), needs the GPU and the buffalo_l detector, so it is
# not part of scripts/ci.sh. (1) mcv-faces equals insightface on the 55 mojo-faces test photos (boxes IoU >= 0.99, landmarks
# within 1 %, the same upright pixels), through the GPU runner. (2) End to end on two real pictures: one Dreamstime
# refused for a face (db044), one without (db000): the face flag, the platform routing and the sidecar.
set -euo pipefail
cd "$(dirname "$0")/.."
P=${MOJO_PROJECTS:-$HOME/Projects/mojo}
M=$P/mojo-faces
D=${MCV_FACES_MODEL:-$HOME/Models/deep-live-cam-models/buffalo_l/buffalo_l/det_10g.onnx}
DBS=${DOAR_BIO_STOCK:-$HOME/Projects/gpu-media/doar-bio-stock}/upload
mkdir -p .work .bin
.venv/bin/mojo build -O3 -I src -I "$P/mojo-faces/src" -I "$P/mojo-imkit/src" -I "$P/mojo-mmap/src" src/stockfaces.mojo -o .bin/mcv-faces 2> .work/build_faces.log || { tail -20 .work/build_faces.log; echo "FAIL build: src/stockfaces.mojo"; exit 1; }
for f in "$M/.work/det/ref.txt" "$D" "$DBS/db044-"*.jpg "$DBS/db000-"*.jpg; do [ -f "$f" ] || { echo "FAIL input: $f missing"; exit 1; }; done
awk '$1 == "n" {print $2}' "$M/.work/det/ref.txt" > .work/det55.txt
gpu-wait run --timeout 600 -- .bin/mcv-faces "$D" .work/faces_gpu.txt .work/det55.txt boxes=1 gpu=16 > /dev/null 2>&1 || { echo "FAIL run: mcv-faces gpu"; exit 1; }
python3 -I "$M/tools/cmp_faces.py" "$M/.work/det/ref.txt" .work/faces_gpu.txt || { echo "FAIL match: mcv-faces vs insightface"; exit 1; }
rm -rf .work/faces_in; mkdir -p .work/faces_in
cp "$DBS/db044-"*.jpg "$DBS/db000-"*.jpg .work/faces_in/
scripts/mcv-stockcheck --faces --sidecar .work/faces_out.jsonl .work/faces_in/*.jpg > .work/faces_out.log || { cat .work/faces_out.log; echo "FAIL stockcheck --faces"; exit 1; }
fail=0
chk() { [ "$2" = "$3" ] && echo "PASS $1: $2" || { echo "FAIL $1: got $2 want $3"; fail=1; }; }
row() { jq -c --arg n "$1" 'select(.file and (.file|test("/" + $n + "-[^/]*$")))' .work/faces_out.jsonl; }
chk "db044 face flag" "$(row db044 | jq -r '.flags | index("face") != null')" true
chk "db044 routes to Adobe only" "$(row db044 | jq -r '[.platforms.adobe, .platforms.dreamstime, .faceReview] | @csv')" "true,false,true"
chk "db000 no face" "$(row db000 | jq -r '.faces.n')" 0
chk "db000 routes to both" "$(row db000 | jq -r '[.platforms.adobe, .platforms.dreamstime, .faceReview] | @csv')" "true,true,false"
chk "sidecar equals output line" "$(cat .work/faces_in/db044-*.stockcheck.json | jq -S -c .)" "$(row db044 | jq -S -c .)"
# pictures imkit's PNG loader refuses (grey, palette, 16-bit, interlaced): the face stage retries them through decode-stock.sh.
# The control run proves the inputs reach the branch: mcv-faces alone must fail on at least one of them.
rm -rf .work/faces_in2; mkdir -p .work/faces_in2
src=$(ls "$DBS/db044-"*.jpg | head -1)
magick "$src" -resize 1536x -type Grayscale .work/faces_in2/grey.png
magick "$src" -resize 1536x -colors 64 PNG8:.work/faces_in2/palette.png
magick "$src" -resize 1536x -depth 16 PNG48:.work/faces_in2/depth16.png
magick "$src" -resize 1536x -interlace PNG PNG24:.work/faces_in2/interlaced.png
ls "$PWD"/.work/faces_in2/*.png > .work/faces_in2.list
gpu-wait run --timeout 600 -- .bin/mcv-faces "$D" .work/faces_ctl.jsonl .work/faces_in2.list gpu=16 > /dev/null 2>&1 || { echo "FAIL run: mcv-faces control"; exit 1; }
chk "control: mcv-faces alone refuses some of the 4 pngs" "$(jq -s '[.[] | select(.error != null)] | length > 0' .work/faces_ctl.jsonl)" true
scripts/mcv-stockcheck --faces .work/faces_out2.jsonl @.work/faces_in2.list > .work/faces_out2.log || { cat .work/faces_out2.log; echo "FAIL stockcheck --faces on the 4 pngs"; exit 1; }
chk "4 odd pngs: no face-stage error" "$(jq -s '[.[] | select(.file and (.faces.error != null or .faces == null))] | length' .work/faces_out2.jsonl)" 0
chk "4 odd pngs: the face is found in each" "$(jq -s '[.[] | select(.file and (.faces.n // 0) >= 1)] | length' .work/faces_out2.jsonl)" 4
[ "$fail" = 0 ] || exit 1
echo "PASS stock_faces"
