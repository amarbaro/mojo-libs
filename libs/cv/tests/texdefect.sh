#!/usr/bin/env bash
# tests/texdefect.sh: blank, seam and stretch (src/mojocv/texdefect.mojo) on planted ortho pictures, all with the same box outline.
#   whitebox  three near-white flat faces            -> blank high, seam 0 (flat faces meet, nothing is textured)
#   shaded    the same white with a gradient on each  -> blank high (shading is divided out)
#   texbox    colour noise over the whole box          -> blank 0, plain 0, seam 0
#   brownbox  flat brown faces (an untextured barrel's colour) -> blank 0 (not grey) but plain high
#   halfbox   noise on one side, flat grey on the other, split by a straight diagonal -> blank near half, seam high
#   streaks   fine noise stretched into vertical lines -> stretch high; noise   same noise, no stretch -> stretch low
# The pictures go through scripts/mcv-visualcheck (decode, chunking) like every library picture.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${MCV_BIN:-.bin/mojo-cv}; w=.work/texdefect-test; rm -rf "$w"; mkdir -p "$w"
[ -x "$bin" ] || { echo "FAIL setup: $bin missing"; exit 1; }
box='polygon 256,120 380,180 380,330 256,390 132,330 132,180'
magick -size 512x512 xc:black -fill white -draw "$box" -depth 8 "$w/boxmask.png"
magick -size 512x512 xc:black -fill 'gray(235)' -draw 'polygon 256,120 380,180 256,240 132,180' -fill 'gray(205)' -draw 'polygon 132,180 256,240 256,390 132,330' -fill 'gray(170)' -draw 'polygon 256,240 380,180 380,330 256,390' -depth 8 "$w/whitebox.png"
magick \( -size 512x512 gradient:'gray(240)-gray(170)' \) "$w/boxmask.png" -compose Multiply -composite -depth 8 "$w/shaded.png"
magick -seed 3 -size 512x512 plasma:fractal -attenuate 0.4 +noise Gaussian "$w/boxmask.png" -compose Multiply -composite -depth 8 "$w/texbox.png"
magick -size 512x512 xc:black -fill white -draw 'polygon 300,100 460,100 460,420 190,420' "$w/boxmask.png" -compose Multiply -composite "$w/part.png"
magick "$w/texbox.png" \( -size 512x512 xc:'gray(225)' \) "$w/part.png" -composite -depth 8 "$w/halfbox.png"
magick -seed 4 -size 128x1 xc:gray50 +noise Random -channel RGB -separate +channel -delete 1,2 -evaluate multiply 0.2 -evaluate add 30% -filter point -resize 512x512\! "$w/s0.png"
magick "$w/s0.png" -depth 8 "$w/boxmask.png" -compose Multiply -composite -depth 8 "$w/streaks.png"
magick -seed 4 -size 512x512 xc:gray50 +noise Random -channel R -separate +channel -evaluate multiply 0.2 -evaluate add 30% "$w/boxmask.png" -compose Multiply -composite -depth 8 "$w/noise.png"
magick -size 512x512 xc:black -fill 'rgb(150,95,50)' -draw 'polygon 256,120 380,180 256,240 132,180' -fill 'rgb(110,70,38)' -draw 'polygon 132,180 256,240 256,390 132,330' -fill 'rgb(80,50,26)' -draw 'polygon 256,240 380,180 380,330 256,390' -depth 8 "$w/brownbox.png"
for n in whitebox shaded texbox halfbox streaks noise brownbox; do printf '%s\t%s\n' "$PWD/$w/$n.png" view; done > "$w/list.tsv"
MCV_BIN=$bin scripts/mcv-visualcheck -j 2 -c 3 "$w/out.jsonl" "$w/list.tsv"
fail=0
ok() { if jq -e "select(.file | endswith(\"/$2.png\")) | $3" "$w/out.jsonl" > /dev/null; then echo "PASS $1"; else echo "FAIL $1: $2 $3 -> $(jq -c "select(.file | endswith(\"/$2.png\")) | [.blank, .seam, .stretch, .plain]" "$w/out.jsonl")"; fail=1; fi; }
if [ "$(wc -l < "$w/out.jsonl")" -eq 7 ]; then echo "PASS rows"; else echo "FAIL rows"; fail=1; fi
ok blank-white whitebox '.blank > 0.6'
ok blank-shaded shaded '.blank > 0.6'
ok blank-textured texbox '.blank < 0.05'
ok plain-brown brownbox '.plain > 0.6 and .blank < 0.05'
ok plain-textured texbox '.plain < 0.1'
ok blank-half halfbox '.blank > 0.2 and .blank < 0.7'
ok seam-flat-faces whitebox '.seam < 1'
ok seam-textured texbox '.seam < 1'
ok seam-half halfbox '.seam > 3'
ok stretch-streaks streaks '.stretch > 0.6'
ok stretch-noise noise '.stretch < 0.3'
exit $fail
