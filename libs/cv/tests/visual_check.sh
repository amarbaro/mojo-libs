#!/usr/bin/env bash
# tests/visual_check.sh: visualCheck on planted pictures. A flat-shaded grey box, a plain disc and a 5-point star on black must
# read flat, colourless and primitive (box, disc) or with a complex outline (star); a colour-noise object with the box outline must
# show colour spread, detail and a low primitive score; a black frame is empty; a full-frame plasma is a photo (no backdrop).
# The checks run through scripts/mcv-visualcheck (decode, chunking, output rows) on PNGs and on a .ppm of the same pixels.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=.bin/mojo-cv; w=.work/visualcheck-test; rm -rf "$w"; mkdir -p "$w"
[ -x "$bin" ] || { echo "FAIL setup: $bin missing"; exit 1; }
box='polygon 256,120 380,180 380,330 256,390 132,330 132,180'
magick -size 512x512 xc:black -fill 'gray(150)' -draw 'polygon 256,120 380,180 256,240 132,180' -fill 'gray(110)' -draw 'polygon 132,180 256,240 256,390 132,330' -fill 'gray(80)' -draw 'polygon 256,240 380,180 380,330 256,390' -depth 8 "$w/flatbox.png"
magick -seed 3 -size 512x512 plasma:fractal -attenuate 0.4 +noise Gaussian \( -size 512x512 xc:black -fill white -draw "$box" \) -compose Multiply -composite -depth 8 "$w/textured.png"
magick -size 512x512 xc:black -fill 'gray(140)' -draw 'circle 256,256 256,100' -depth 8 "$w/disc.png"
magick -size 512x512 xc:black -fill 'gray(140)' -draw 'polygon 256,60 300,200 450,200 330,290 375,440 256,350 137,440 182,290 62,200 212,200' -depth 8 "$w/star.png"
magick -size 512x512 xc:black -depth 8 "$w/empty.png"
magick -seed 5 -size 512x512 plasma:fractal -depth 8 "$w/photo.png"
magick "$w/textured.png" -depth 8 "ppm:$w/textured.ppm"
magick -size 512x512 xc:'gray(128)' -depth 8 "$w/uniform.png"
for n in flatbox textured disc star; do printf '%s\t%s\n' "$PWD/$w/$n.png" "preview"; done > "$w/list.tsv"
printf '%s\t%s\n' "$PWD/$w/empty.png" view "$PWD/$w/photo.png" image "$PWD/$w/uniform.png" image >> "$w/list.tsv"
printf '%s\t%s\n' "$PWD/$w/missing.png" view >> "$w/list.tsv"   # a file that is not there must give an error row, not a number
MCV_BIN=$bin scripts/mcv-visualcheck -j 2 -c 4 "$w/out.jsonl" "$w/list.tsv"
printf '%s\t%s\n' "$PWD/$w/textured.ppm" preview > "$w/l2.tsv"
MCV_BIN=$bin scripts/mcv-visualcheck "$w/out2.jsonl" "$w/l2.tsv"
fail=0
# ok NAME PICTURE JQ-BOOLEAN: the boolean is evaluated on that picture's row
ok() { if jq -e "select(.file | endswith(\"/$2.png\")) | $3" "$w/out.jsonl" > /dev/null; then echo "PASS $1"; else echo "FAIL $1: $2 $3"; fail=1; fi; }
if [ "$(wc -l < "$w/out.jsonl")" -eq 8 ]; then echo "PASS rows"; else echo "FAIL rows"; fail=1; fi
# verdicts: a flat grey shape reads bad on a preview, a colour-noise object reads ok (the model is monotone), blank and uniform are bad, a photo is ok
ok verdict-flat-box flatbox '.verdict == "bad" and .score < 20 and (.reason | startswith("flat="))'
ok verdict-flat-disc disc '.verdict == "bad"'
ok verdict-textured textured '.verdict == "ok" and .score > 90 and .reason == ""'
ok verdict-empty empty '.verdict == "bad" and (.reason | startswith("blank"))'
ok verdict-uniform uniform '.verdict == "bad" and (.reason | startswith("blank"))'   # one flat colour is all backdrop
ok verdict-photo photo '.verdict == "ok"'
ok missing-is-error missing '.error != null and .chroma == null'
ok empty empty '.empty == 1 and .fill == 0'
ok flatbox-flat flatbox '.flat > 0.9 and .hfshare < 0.1 and .chroma < 1 and .palette <= 4 and .prim > 0.8'
ok textured-detail textured '.hfshare > 0.5 and .chroma > 20 and .palette > 20 and .huen > 6 and .prim < 0.1'
ok disc-round disc '.complex < 1.2 and .solid > 0.95 and .prim > 0.8'
ok star-complex star '.complex > 3 and .solid < 0.6 and .corners >= 8 and .prim < 0.1'
ok photo-no-backdrop photo '.bgbad > 0.9 and .fill == 1'
# the box outline is the same for the flat and the textured picture, so the silhouette numbers must not depend on the surface
if jq -n -e --slurpfile r "$w/out.jsonl" '($r | map(select(.file | endswith("/flatbox.png")))[0]) as $a | ($r | map(select(.file | endswith("/textured.png")))[0]) as $b | (($a.complex - $b.complex) | fabs) < 0.05 and (($a.solid - $b.solid) | fabs) < 0.05' > /dev/null; then echo "PASS same-outline"; else echo "FAIL same-outline"; fail=1; fi
# decoding the same pixels from a .ppm gives the same row as from the PNG
x=$(jq -c 'del(.file)' "$w/out2.jsonl"); y=$(jq -c 'select(.file | endswith("/textured.png")) | del(.file)' "$w/out.jsonl")
if [ "$x" = "$y" ]; then echo "PASS ppm-eq-png"; else echo "FAIL ppm-eq-png"; fail=1; fi
exit $fail
