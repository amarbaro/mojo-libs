#!/usr/bin/env bash
# tests/capture_replay.sh LIST (gate G1.7, plan row R12a): replay the shots of LIST (one picture path per line, arrival order) through
# scripts/mcv-capture-qa and check three things.
#  1 equal: the finalized rows equal the rows of one batch run (mcv-stockgroup over the whole list) with the same cached embeddings,
#    row by row, and every item close was announced; the rows that closing an item changed are counted and logged.
#  2 silent: no shot with hand < 0.02 (the clean shots) raises anything; every shot at or above it raises `hand`.
#  3 planted: a truncated file, a late time stamp, a pasted hand, a defocused copy and a cut tape raise their own flag (tape: a
#    note), each beside a control (the same picture, unchanged, later name) that raises nothing.
#  4 sync (R12b): `mcv-capture-qa sync` against a fake adb (MCV_ADB, no device touched): no device and offline are BLOCK (exit 3), a
#    file that is still growing is not pulled and a later name waits for it, a hidden .pending twin is never pulled, the pulled bytes equal
#    the file, a stable but truncated file reaches the verdict as truncated, the phone's clock offset is recorded, every shot has its
#    four stamps in order, and a second run delivers nothing again.
#  5 views (R12c): with MCV_QA_VIEWS=front,back every closed event carries the view fields; its view count equals the batch's per item
#    and the items with one view are exactly the closes that list `back` as missing; the closes of items with two views list nothing.
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
export MCV_RAW=$raw MCV_EMBED_ARGS=${MCV_EMBED_ARGS:---cpu} MCV_QA_VIEWS=front,back
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

# 5 views (R12c): the close events of the replay above, against the batch rows
ev=$st/replay.out
nev=$(jq -c 'select(.event == "closed")' "$ev" | wc -l)
chk "every closed event ($nev) carries views, view_labels, missing_view, arrival_views, merged_views and rank_changed" "[ \"\$(jq -c 'select(.event == \"closed\") | select(has(\"views\") and has(\"view_labels\") and has(\"missing_view\") and has(\"arrival_views\") and has(\"merged_views\") and has(\"rank_changed\"))' $ev | wc -l)\" = $nev ]"
jq -s -c 'map(select(.group != null)) | group_by(.group) | map({g: .[0].group, v: (map(.view) | unique | length)})' "$st/batch/cv.jsonl" > "$w/views.batch"
jq -s -c 'map(select(.event == "closed") | {g: (if .group == "end" then .last_group else .group end), v: .views}) | sort_by(.g)' "$ev" > "$w/views.ev"
chk "the view count of every closed item equals the batch's ($items items)" "cmp -s $w/views.batch $w/views.ev"
one=$(jq 'map(select(.v < 2)) | length' "$w/views.batch")
miss=$(jq -c 'select(.event == "closed" and (.missing_view | index("back")))' "$ev" | wc -l)
chk "the shoot has items with one view ($one), so the rule can fire" "[ $one -gt 0 ]"
chk "closes that list back as missing ($miss) are the items with one view ($one); none of the others does" "[ $miss = $one ] && [ \"\$(jq -c 'select(.event == \"closed\" and .views >= 2 and (.missing_view | length) > 0)' $ev | wc -l)\" = 0 ]"
chk "view labels follow the order of first appearance: front, back, then extra" "[ \"\$(jq -c 'select(.event == \"closed\") | .view_labels | select(.[0] != \"front\" or (length > 1 and .[1] != \"back\") or (length > 2 and (.[2:] | map(. != \"extra\") | any)))' $ev | wc -l)\" = 0 ]"
echo "logged: merged views $(jq -s 'map(select(.event == "closed") | .merged_views) | add' "$ev") over $(jq -s 'map(select(.event == "closed" and .merged_views > 0)) | length' "$ev") items, rows whose rank or dup_of changed between arrival and close $(jq -s 'map(select(.event == "closed") | .rank_changed) | add' "$ev")"

# 4 sync (R12b): a fake adb with three files: b1 stable, b2 growing until its 4th listing (a hidden .pending twin beside it), b3 truncated
rm -rf "$w/sy" "$w/sy0" "$w/sy3"; F=$w/fake; rm -rf "$F"; mkdir -p "$F/files" "$F/out"; echo 0 > "$F/poll"; echo device > "$F/state"; echo 7 > "$F/skew"
b1=$(sed -n 1p "$list"); b2=$(sed -n 2p "$list"); b3=$(sed -n 3p "$list")
cp "$b1" "$F/files/"; cp "$b2" "$F/files/"; head -c $(( $(stat -c %s "$b3") / 4 )) "$b3" > "$F/files/${b3##*/}"; cp "$b2" "$F/files/.pending-1-${b2##*/}"; cp "$b1" "$F/files/IMG_20200101_000000.jpg"; touch -d @1000 "$F/files/IMG_20200101_000000.jpg"
cat > "$F/adb" <<'FAKE'
#!/usr/bin/env bash
# a fake adb for tests/capture_replay.sh: serial fake01 only, the calls of `mcv-capture-qa sync`, no input, no write to the "phone"
F=${FAKE:?}; [ "$1" = -s ] || exit 2; ser=$2; shift 2
[ "$ser" = fake01 ] || { echo "error: device '$ser' not found" >&2; exit 1; }
size() { local s; s=$(stat -c %s "$F/files/$1"); [ "$1" = "$GROW" ] && [ "$(cat "$F/poll")" -lt 4 ] && s=$(( $(cat "$F/poll") * 3000 )); echo "$s"; }
case $1 in
  get-state) cat "$F/state";;
  shell) case "${*:2}" in
    "date +%s") echo $(( $(date +%s) + $(cat "$F/skew") ));;
    *stat*) echo $(( $(cat "$F/poll") + 1 )) > "$F/poll"; for g in "$F"/files/*; do printf '%s %s %s\r\n' "$(size "${g##*/}")" "$(( $(stat -c %Y "$g") + $(cat "$F/skew") ))" "${g##*/}"; done;;
    *) exit 2;;
  esac;;
  pull) b=${2##*/}; s=$(size "$b"); head -c "$s" "$F/files/$b" > "$3"; echo "$b poll=$(cat "$F/poll") bytes=$s" >> "$F/pulls";;
  *) exit 2;;
esac
FAKE
chmod +x "$F/adb"
sy() { MCV_ADB=$F/adb FAKE=$F GROW=${b2##*/} scripts/mcv-capture-qa sync "$@"; }
rcs() { local r=0; "$@" > "$F/out/o" 2> "$F/out/e" || r=$?; echo "$r"; }
chk "no such device is BLOCK (exit 3)" "[ \"\$(rcs sy nodev $w/sy0)\" = 3 ] && grep -q '^BLOCK sync: no device' $F/out/e"
echo offline > "$F/state"
chk "an offline device is BLOCK (exit 3)" "[ \"\$(rcs sy fake01 $w/sy0)\" = 3 ] && grep -q offline $F/out/e"
echo device > "$F/state"; : > "$F/pulls"; echo 0 > "$F/poll"
sy fake01 "$w/sy" --polls 8 --gap 0.1 --since 100000 > "$F/out/sync.out" 2>&1 || { tail -5 "$F/out/sync.out"; echo "FAIL sync: mcv-capture-qa sync against the fake adb"; exit 1; }
sh=$w/sy/shots.jsonl
chk "three shots reach the verdict, in time order" "[ \"\$(jq -r .file $sh | tr '\\n' ' ')\" = \"${b1##*/} ${b2##*/} ${b3##*/} \" ]"
chk "the growing file is pulled once, only when its size held on two listings, and whole" "[ \"\$(grep -c \"^${b2##*/} \" $F/pulls)\" = 1 ] && [ \"\$(grep \"^${b2##*/} \" $F/pulls | sed 's/.*poll=\\([0-9]*\\) .*/\\1/')\" -ge 5 ] && cmp -s $F/files/${b2##*/} $w/sy/inbox/${b2##*/}"
chk "the stable file is pulled at its second listing; the hidden .pending twin is never listed or pulled" "grep -q \"^${b1##*/} poll=2 \" $F/pulls && ! grep -q pending $F/pulls"
chk "the stable but truncated file raises truncated" "[ \"\$(jq -r --arg f ${b3##*/} 'select(.file == \$f) | .raise | index(\"truncated\") != null' $sh)\" = true ]"
chk "a picture older than --since (phone mtime 1007) is never pulled; --new alone would skip all three (phone mtimes are older than its now)" "! grep -q IMG_20200101 $F/pulls && [ \"\$(MCV_ADB=$F/adb FAKE=$F GROW=x scripts/mcv-capture-qa sync fake01 $w/sy3 --polls 3 --gap 0.1 --new | tail -1)\" = 'PASS sync: 0 delivered in all, 0 seen' ]"
chk "the phone clock 7 s ahead is recorded: offset between 5 and 9 s" "[ \"\$(jq '.offset_s > 5 and .offset_s < 9' $w/sy/sync/clock.json)\" = true ]"
chk "every shot has seen, stable, pulled and verdict stamps in order" "[ \"\$(jq -s 'map(select(.t_seen <= .t_stable and .t_stable <= .t_pulled and .t_pulled <= .t_verdict)) | length' $w/sy/sync/sync.jsonl)\" = 3 ]"
np=$(wc -l < "$F/pulls")
sy fake01 "$w/sy" --polls 2 --gap 0.1 --since 100000 > "$F/out/sync2.out" 2>&1
chk "a second run delivers nothing again ($(wc -l < $sh) shots, $(wc -l < $F/pulls) pulls)" "[ \"\$(wc -l < $sh)\" = 3 ] && [ \"\$(wc -l < $F/pulls)\" = $np ]"
[ "$fail" = 0 ] || { echo "FAIL capture_replay"; exit 1; }
echo "PASS capture_replay"
