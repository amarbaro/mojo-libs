#!/usr/bin/env bash
# tests/capture_replay.sh LIST (gate G1.7, plan row R12a): replay the shots of LIST (one picture path per line, arrival order) through
# scripts/mcv-capture-qa and check three things.
#  1 equal: the finalized rows equal the rows of one batch run (mcv-stockgroup over the whole list) with the same cached embeddings,
#    row by row, and every item close was announced; the rows that closing an item changed are counted and logged.
#  2 silent: no shot with hand < 0.02 (the clean shots) raises anything; every shot at or above it raises `hand`.
#  3 planted: a truncated file, a late time stamp, a pasted hand, a defocused copy and a cut tape raise their own flag (tape: a
#    note), each beside a control (the same picture, unchanged, later name) that raises nothing.
# Embeddings are the CPU runner (MCV_EMBED_ARGS=--cpu: no GPU job; batch and replay share the cache, so the equality is the point).
# BLOCK (exit 3) when the list, a picture, a binary or the originals are missing; never a skip.
set -euo pipefail
cd "$(dirname "$0")/.."
list=${1:?usage: tests/capture_replay.sh LIST}
block() { echo "BLOCK capture_replay: $1"; exit 3; }
[ -f "$list" ] || block "list $list missing"; list=$(realpath -- "$list")
[ -x .bin/mojo-cv ] && [ -x .bin/mcv-labels ] || block ".bin/mojo-cv or .bin/mcv-labels missing"
n=$(grep -c . "$list" || true); [ "$n" -gt 0 ] || block "empty list"
while IFS= read -r f; do [ -f "$f" ] || block "shot $f missing"; done < "$list"
first=$(head -1 "$list"); raw=${MCV_RAW:-$(dirname "$(dirname "$first")")/raw}
[ -d "$raw" ] || block "originals $raw missing (EXIF time): set MCV_RAW"
export MCV_RAW=$raw MCV_EMBED_ARGS=${MCV_EMBED_ARGS:---cpu}
w=.work/capture-replay; mkdir -p "$w"; rm -rf "$w/state" "$w/planted"; export MCV_CACHE=$PWD/$w/cache
fail=0; chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1: $2"; fail=1; fi; }
st=$w/state

scripts/mcv-capture-qa replay "$list" "$st" > "$w/replay.log" 2>&1 || { tail -5 "$w/replay.log"; echo "FAIL replay: mcv-capture-qa replay"; exit 1; }
tail -1 "$w/replay.log"
norm() { jq -S -c . "$1" | sort; }
# 1 equal
chk "$n finalized rows" "[ \"\$(wc -l < $st/final.jsonl)\" = $n ] && [ \"\$(wc -l < $st/batch/cv.jsonl)\" = $n ]"
norm "$st/final.jsonl" > "$w/final.norm"; norm "$st/batch/cv.jsonl" > "$w/batch.norm"
chk "finalized rows equal the batch rows (byte for byte, jq -S)" "cmp -s $w/final.norm $w/batch.norm"
items=$(jq -s 'map(select(.group != null) | .group) | unique | length' "$st/batch/cv.jsonl")
closed=$(jq -c 'select(.event == "closed" and .group != "end")' "$st/replay.out" | wc -l)
chk "every item close announced ($closed closes before the last item, $items items)" "[ $closed -eq $((items - 1)) ]"
norm "$st/arrival.jsonl" > "$w/arrival.norm"
chk "control: the rows as they stood at arrival differ from the batch (the equality can fail)" "! cmp -s $w/arrival.norm $w/batch.norm"
chg=$(jq -s --slurpfile a "$st/arrival.jsonl" 'map({(.file): .}) | add as $F | [$a[] | select((.view != $F[.file].view) or (.view_rank != $F[.file].view_rank) or (.dup_of != $F[.file].dup_of) or (.group != $F[.file].group))] | length' "$st/final.jsonl")
echo "logged: $chg of $n rows changed (group, view, view_rank, dup_of) between arrival and item close"
S=/home/mario/Projects/ebay.de/.work/stock-20261122/cv.jsonl
[ -f "$S" ] && echo "logged: stored ebay.de cv.jsonl equals the batch rows for $(comm -12 <(norm "$S") "$w/batch.norm" | wc -l) of $n shots (other binary or embedding arm: not a gate)"
# 2 silent
clean=$(jq -s -r '.[] | select(.hand < 0.02 and (.empty | not)) | .file' "$st/batch/cv.jsonl")
nc=$(printf '%s\n' "$clean" | grep -c . || true)
raised=$(jq -s -r --rawfile c <(printf '%s\n' "$clean") '($c | split("\n")) as $C | map(select(.file as $f | $C | index($f)) | select(.verdict == "raise")) | length' "$st/shots.jsonl")
chk "clean shots ($nc, hand under 0.02) raise nothing ($raised raised)" "[ $raised = 0 ]"
hand=$(jq -s '[.[] | select(.hand >= 0.02)] | length' "$st/batch/cv.jsonl")
hr=$(jq -s '[.[] | select(.raise | index("hand"))] | length' "$st/shots.jsonl")
chk "shots at hand 0.02 or more ($hand) all raise hand ($hr)" "[ $hr = $hand ]"
# 3 planted: from the first clean shot with a tape (tape_conf 0.2 or more, sharp over 3000)
src=$(jq -s -r 'map(select(.hand == 0 and .px_per_cm != null and .tape_conf >= 0.2 and .sharp > 3000)) | .[0].file' "$st/batch/cv.jsonl")
[ -n "$src" ] && [ "$src" != null ] || block "no clean shot with a tape in the list"
spath=$(awk -v s="$src" '{ n = split($0, a, "/"); if (a[n] == s) print }' "$list" | head -1)
read -r sw sh < <(jq -s -r --arg f "$src" '.[] | select(.file == $f) | "\(.w) \(.h)"' "$st/batch/cv.jsonl")
p=$w/planted; mkdir -p "$p/ps"
lastt=$(jq -r '.t' "$st/last.json"); jq -c -n --argjson t "$lastt" '{t: $t, tape: true}' > "$p/ps/last.json"
magick "$spath" \( "$spath" -fill 'gray(35%)' -colorize 100 \) \( "$spath" -fx 'r>0.65&&g>0.5&&b<0.45&&(r-b)>0.35?1:0' -morphology Dilate Disk:4 \) -composite "$p/IMG_20261124_000000.jpg"
magick "$spath" -fill 'rgb(224,172,150)' -draw "rectangle $((sw * 55 / 100)),$((sh * 60 / 100)) $((sw - 1)),$((sh - 1))" "$p/IMG_20261124_000100.jpg"
magick "$spath" -blur 0x14 "$p/IMG_20261124_000200.jpg"
head -c $(( $(stat -c %s "$spath") / 4 )) "$spath" > "$p/IMG_20261124_000300.jpg"
cp "$spath" "$p/IMG_20261122_000100.jpg"
for c in 0 1 2 3; do cp "$spath" "$p/IMG_20261124_0010${c}0.jpg"; done  # controls: later names, unchanged pixels
q() { scripts/mcv-capture-qa qa "$1" "$p/ps"; }
v() { q "$p/$1" | jq -r "$2"; }
chk "planted truncated file raises truncated" "[ \"\$(v IMG_20261124_000300.jpg '.raise | index(\"truncated\") != null')\" = true ]"
chk "planted late time stamp raises late" "[ \"\$(v IMG_20261122_000100.jpg '.raise | index(\"late\") != null')\" = true ]"
chk "planted hand raises hand" "[ \"\$(v IMG_20261124_000100.jpg '.raise | index(\"hand\") != null')\" = true ]"
chk "planted defocus raises defocus" "[ \"\$(v IMG_20261124_000200.jpg '.raise | index(\"defocus\") != null')\" = true ]"
chk "planted cut tape notes tape_lost" "[ \"\$(v IMG_20261124_000000.jpg '.notes | index(\"tape_lost\") != null')\" = true ]"
chk "control of the truncated, hand, defocus and late plants raises nothing" "[ \"\$(for c in 0 1 2 3; do v IMG_20261124_0010\${c}0.jpg '.raise | length'; done | tr -d '\\n')\" = 0000 ]"
chk "control of the cut tape keeps its tape (no tape_lost)" "[ \"\$(v IMG_20261124_001000.jpg '.notes | index(\"tape_lost\") == null')\" = true ]"
[ "$fail" = 0 ] || { echo "FAIL capture_replay"; exit 1; }
echo "PASS capture_replay"
