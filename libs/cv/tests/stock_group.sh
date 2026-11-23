#!/usr/bin/env bash
# tests/stock_group.sh: stockPhoto (subject box, sharpness) and stockGroup (items, views, duplicates) on planted inputs, plus the
# hand-labelled boxes of the ebay.de stock shoot when its photos are on this machine (tests/stock_hand_boxes.tsv).
# Planted box cases: a dark cloth with a yellow tape band and a pale disc (box must find the disc), the same with a skin-coloured hand
# entering from the bottom edge (box must still find the disc), and an empty cloth (no box, empty = true).
# Planted grouping: 4 items (pairs 8 s apart, new item 60 s later), one repeated shot (cosine 0.99) that must name its twin, one empty frame.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=.bin/mojo-cv; w=.work/stockgroup-test; rm -rf "$w"; mkdir -p "$w"
[ -x "$bin" ] || { echo "FAIL setup: $bin missing"; exit 1; }
cloth=(-seed 7 -depth 8 -size 640x480 xc:gray12 +noise Gaussian -attenuate 0.3 -blur 0x1)
yellow=(-fill 'rgb(235,215,0)' -draw 'rectangle 0,40 639,85')
disc=(-fill 'rgb(225,225,225)' -draw 'ellipse 330,270 70,60 0,360')
hand=(-fill 'rgb(224,172,150)' -draw 'rectangle 380,330 639,479')
magick "${cloth[@]}" "${yellow[@]}" "${disc[@]}" -depth 8 "ppm:$w/disc.ppm"
magick "${cloth[@]}" "${yellow[@]}" "${disc[@]}" "${hand[@]}" -depth 8 "ppm:$w/hand.ppm"
magick "${cloth[@]}" "${yellow[@]}" -depth 8 "ppm:$w/empty.ppm"
# a tape measure: 1 mm ticks every 6 px, 1 cm ticks every 60 px, so 60 px per cm
ticks=(); for ((x = 3; x < 640; x += 6)); do if ((x % 60 == 3)); then ticks+=(-draw "line $x,58 $x,84"); else ticks+=(-draw "line $x,74 $x,84"); fi; done
magick "${cloth[@]}" "${yellow[@]}" -fill black -stroke black "${ticks[@]}" "${disc[@]}" -depth 8 "ppm:$w/tape.ppm"
for n in disc hand empty tape; do printf '%s\t%s\n' "$w/$n.ppm" "$n"; done > "$w/batch.tsv"
"$bin" stockPhoto "$w/photo.jsonl" "$w/batch.tsv"
fail=0
chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1: $2"; fail=1; fi; }
row() { jq -c "select(.file == \"$1\")" "$w/photo.jsonl"; }
# truth box of the disc: x 260..400, y 210..330
for n in disc hand; do
  iou=$(row $n | jq -r '.box as $b | if $b == null then 0 else
    (([$b[2], 400] | min) - ([$b[0], 260] | max)) as $ix | (([$b[3], 330] | min) - ([$b[1], 210] | max)) as $iy
    | (if $ix > 0 and $iy > 0 then $ix * $iy else 0 end) as $i | $i / (($b[2] - $b[0]) * ($b[3] - $b[1]) + 140 * 120 - $i) end')
  chk "box $n IoU $iou >= 0.7" "awk 'BEGIN { exit !($iou >= 0.7) }'"
done
chk "empty cloth: no box" "[ \"\$(row empty | jq -r '.box')\" = null ]"
chk "empty cloth: empty = true" "[ \"\$(row empty | jq -r '.empty')\" = true ]"
chk "disc: empty = false" "[ \"\$(row disc | jq -r '.empty')\" = false ]"
pxcm=$(row tape | jq -r '.tapePxCm')
chk "tape: $pxcm px per cm within 3 % of 60" "awk 'BEGIN { exit !($pxcm > 58.2 && $pxcm < 61.8) }'"
chk "no tick pattern: no scale or low confidence" "[ \"\$(row disc | jq -r '.tapeConf < 0.15')\" = true ]"
chk "sharpness positive" "[ \"\$(row disc | jq '.lapvar > 0')\" = true ]"
# grouping: embeddings from fixed seeds
.venv/bin/python -I - "$w" <<'EOF'
import sys, numpy as np
w = sys.argv[1]; rng = np.random.default_rng(7)
names = ['a1', 'a2', 'b1', 'b2', 'b2dup', 'c1', 'c2', 'blank', 'd1', 'd2']
t = [0, 8, 68, 76, 77, 140, 150, 160, 230, 238]
base = {k: rng.normal(size=768) for k in 'abcd'}
E = []
for n in names:
    if n == 'blank': v = rng.normal(size=768)
    elif n == 'b2dup': v = E[3] + 0.005 * rng.normal(size=768)
    else: v = base[n[0]] + (0.6 * rng.normal(size=768) if n.endswith('2') else 0)
    E.append(v / np.linalg.norm(v))
np.array(E, dtype=np.float32).tofile(w + '/emb.f32')
with open(w + '/in.tsv', 'w') as f:
    for i, n in enumerate(names):
        f.write('%s\t%d\t%d\t%d\t%016x\n' % (n, 1000 + t[i], 4000 + (50 if n == 'b2dup' else 100 + i * 10), 1 if n == 'blank' else 0, (i * 0x9E3779B97F4A7C15) % (1 << 64)))
EOF
"$bin" stockGroup "$w/grp.tsv" "$w/in.tsv" "$w/emb.f32" > /dev/null
col() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c }' "$w/grp.tsv"; }
chk "pairs share an item" "[ \"\$(col a1 2)\" = \"\$(col a2 2)\" ] && [ \"\$(col b1 2)\" = \"\$(col b2 2)\" ] && [ \"\$(col c1 2)\" = \"\$(col c2 2)\" ]"
chk "60 s later is a new item" "[ \"\$(col a2 2)\" != \"\$(col b1 2)\" ] && [ \"\$(col b2 2)\" != \"\$(col c1 2)\" ] && [ \"\$(col c2 2)\" != \"\$(col d1 2)\" ]"
chk "empty frame has no item" "[ \"\$(col blank 2)\" = -1 ]"
chk "repeated shot names its twin" "[ \"\$(col b2dup 5)\" = b2 ] || [ \"\$(col b2 5)\" = b2dup ]"
chk "the sharper twin ranks 0" "[ \"\$(col b2 4)\" = 0 ] && [ \"\$(col b2dup 4)\" = 1 ]"
chk "front and back stay two views" "[ \"\$(col a1 3)\" != \"\$(col a2 3)\" ]"
# the labelled hand photos of the real shoot (not in the repo): mean IoU must not fall under the recorded 0.50
photos=${MCV_STOCK_WORK:-$HOME/Projects/ebay.de/.work/stock-20261122/work}
if [ -d "$photos" ]; then
  : > "$w/hb.tsv"
  while IFS=$'\t' read -r n x0 y0 x1 y1; do
    scripts/decode-stock.sh "$photos/$n.jpg" "$w/$n" 2>/dev/null; p=$w/$n.mcv; [ -f "$w/$n.ppm" ] && p=$w/$n.ppm; printf '%s\t%s\n' "$p" "$n" >> "$w/hb.tsv"
  done < tests/stock_hand_boxes.tsv
  "$bin" stockPhoto "$w/hb.jsonl" "$w/hb.tsv"
  read -r mean pass < <(jq -r --rawfile l tests/stock_hand_boxes.tsv -s '
    ($l | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): [.[1:][] | tonumber]}) | add) as $L
    | map(. as $r | $L[$r.file] as $t | (if $r.box == null then 0 else
        ($r.box | [.[0] / $r.w, .[1] / $r.h, .[2] / $r.w, .[3] / $r.h]) as $b
        | (([$b[2], $t[2]] | min) - ([$b[0], $t[0]] | max)) as $ix | (([$b[3], $t[3]] | min) - ([$b[1], $t[1]] | max)) as $iy
        | (if $ix > 0 and $iy > 0 then $ix * $iy else 0 end) as $i
        | $i / (($b[2] - $b[0]) * ($b[3] - $b[1]) + ($t[2] - $t[0]) * ($t[3] - $t[1]) - $i) end))
    | "\(add / length) \(map(select(. >= 0.7)) | length)"' "$w/hb.jsonl")
  echo "hand boxes: mean IoU $mean, $pass of $(wc -l < tests/stock_hand_boxes.tsv) at IoU >= 0.7 (target 0.7 each: not met, recorded)"
  chk "hand boxes: mean IoU >= 0.50" "awk 'BEGIN { exit !($mean >= 0.50) }'"
else
  echo "skip hand boxes: $photos not on this machine"
fi
[ "$fail" = 0 ] || { echo "FAIL stock_group"; exit 1; }
echo "PASS stock_group"
