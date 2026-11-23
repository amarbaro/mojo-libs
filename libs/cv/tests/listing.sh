#!/usr/bin/env bash
# tests/listing.sh LIST (gate G2.3, plan row R14a): the listing drafts of scripts/mcv-listing for the pictures of LIST (one path per
# line, arrival order, the shoot-194.list format; it must hold whole items, at least one item without a tape and one empty frame).
#  1 schema: every draft passes `mcv-listing check`.
#  2 size oracle: for every item, size is null exactly when no photo of the item has a tape scale, a subject box and hand < 0.02; else
#    the sized photo is one of those and w_cm, h_cm are within 0.06 cm of its row's box_cm (a field stockPhoto writes itself, not the
#    box / px_per_cm the draft is made from); the text reads ~N x M cm (tape est.).
#  3 planted: a bad size (1.5 times the width), an invalid job (no pending list, status listed, text without "(tape est.)", an empty
#    frame as a photo, a matte claim) each fail `check`; the unchanged draft beside each passes.
#  4 controls: an empty frame gives no draft (exit 4, nothing written); an item without a tape has no size and no number in it.
#  5 local: status draft_local everywhere, no network word in the script, no groups.json written or accepted as --out.
# Not here (R14b, R7): product pixels byte-equal inside the eroded matte, background and turntable. Pictures are embedded on the CPU
# (MCV_EMBED_ARGS=--cpu), the cache is shared with tests/capture_replay.sh. BLOCK (exit 3) when the list, a picture, a binary or the
# originals are missing; never a skip.
set -euo pipefail
cd "$(dirname "$0")/.."
list=${1:?usage: tests/listing.sh LIST}
block() { echo "BLOCK listing: $1"; exit 3; }
[ -f "$list" ] || block "list $list missing"; list=$(realpath -- "$list")
[ -x .bin/mojo-cv ] && [ -x .bin/mcv-labels ] || block ".bin/mojo-cv or .bin/mcv-labels missing"
n=$(grep -c . "$list" || true); [ "$n" -gt 0 ] || block "empty list"
while IFS= read -r f; do [ -f "$f" ] || block "picture $f missing"; done < "$list"
first=$(head -1 "$list"); raw=${MCV_RAW:-$(dirname "$(dirname "$first")")/raw}
[ -d "$raw" ] || block "originals $raw missing (EXIF time): set MCV_RAW"
export MCV_RAW=$raw MCV_EMBED_ARGS=${MCV_EMBED_ARGS:---cpu} MCV_QA_VIEWS=front,back
w=.work/listing; mkdir -p "$w"; rm -rf "$w/rows" "$w/drafts" "$w/planted"; export MCV_CACHE=${MCV_CACHE:-$PWD/.work/capture-replay/cache}
mkdir -p "$MCV_CACHE"
fail=0; chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1: $2"; fail=1; fi; }
R=$w/rows D=$w/drafts; mkdir -p "$R"

MCV_LIST=$list scripts/mcv-stockgroup "$R" > "$w/group.log" 2>&1 || { tail -5 "$w/group.log"; echo "FAIL group: mcv-stockgroup over the list"; exit 1; }
scripts/mcv-listing draft "$R" --out "$D" > "$w/draft.log" 2>&1 || { tail -5 "$w/draft.log"; echo "FAIL draft: mcv-listing draft"; exit 1; }
items=$(jq length "$R/cv-groups.json"); nd=$(ls "$D"/item-*.json | wc -l)
empty=$(jq -s -r 'map(select(.empty)) | .[0].file // empty' "$R/cv.jsonl")
echo "list: $n pictures, $items items, $nd drafts, empty frames: $(jq -s 'map(select(.empty)) | length' "$R/cv.jsonl")"
[ -n "$empty" ] || block "no empty frame in the list: the no-draft control needs one"

# 1 schema
bad=0; for f in "$D"/item-*.json; do scripts/mcv-listing check "$R" "$f" > /dev/null 2> "$w/check.err" || { bad=$((bad + 1)); cat "$w/check.err"; }; done
chk "every one of $nd drafts passes the schema and recomputation check" "[ $bad = 0 ] && [ $nd = $items ]"

# 2 size oracle, from the rows' own box_cm
jq -c -n --slurpfile g "$R/cv-groups.json" --slurpfile r "$R/cv.jsonl" '$g[0] | map(. as $it | ($r | map(select(.group == $it.group and .px_per_cm != null and .box != null and .hand < 0.02))) as $ok | {item: .group, usable: ($ok | length), photos: ($ok | map(.file))})' > "$w/usable.json"
badsz=0; sized=0; unsized=0
while read -r item usable photos; do
  f=$D/item-$(printf %03d "$item").json
  if [ "$usable" = 0 ]; then
    [ "$(jq -c '.size' "$f")" = null ] || badsz=$((badsz + 1)); unsized=$((unsized + 1))
  else
    sized=$((sized + 1))
    ph=$(jq -r '.size.provenance.photo' "$f")
    jq -e --arg p "$ph" --argjson ok "$photos" --slurpfile rows "$R/cv.jsonl" '($rows | map(select(.file == $p)) | .[0].box_cm) as $b | (($ok | index($p)) != null) and (((.size.w_cm - $b[0]) | fabs) <= 0.06) and (((.size.h_cm - $b[1]) | fabs) <= 0.06) and (.size.text | test("^~[0-9]+ x [0-9]+ cm \\(tape est\\.\\)$"))' "$f" > /dev/null || badsz=$((badsz + 1))
  fi
done < <(jq -r '.[] | "\(.item) \(.usable) \(.photos | tojson)"' "$w/usable.json")
chk "size oracle: $sized sized items match box_cm within 0.06 cm, $unsized without a usable tape have size null" "[ $badsz = 0 ] && [ $sized -gt 0 ] && [ $unsized -gt 0 ]"

# 3 planted, each beside its control
p=$w/planted; mkdir -p "$p"; src=$(for f in "$D"/item-*.json; do jq -e '.size != null' "$f" > /dev/null && { echo "$f"; break; }; done)
[ -n "$src" ] || block "no sized item in the list"
ck() { scripts/mcv-listing check "$R" "$1" > /dev/null 2>&1; }
chk "control: the unchanged sized draft passes" "ck $src"
jq '.size.w_cm = (.size.w_cm * 1.5)' "$src" > "$p/bad-size.json"
jq 'del(.pending)' "$src" > "$p/no-pending.json"
jq '.status = "listed"' "$src" > "$p/listed.json"
jq '.size.text |= sub(" \\(tape est\\.\\)"; "")' "$src" > "$p/no-est.json"
jq --arg e "${empty##*/}" '.photos[0].file = $e' "$src" > "$p/empty-photo.json"
jq '.matte = {applied: true}' "$src" > "$p/matte.json"
jq '.size.provenance.px_per_cm = 1' "$src" > "$p/scale.json"
for c in bad-size no-pending listed no-est empty-photo matte scale; do chk "planted $c fails the check" "! ck $p/$c.json"; done

# 4 controls
before=$(ls "$D" | wc -l); rc=0; scripts/mcv-listing draft "$R" --out "$D" --file "$empty" > /dev/null 2> "$w/empty.err" || rc=$?
chk "an empty frame (${empty##*/}) gives no draft: exit 4, NODRAFT, nothing written" "[ $rc = 4 ] && grep -q '^NODRAFT' $w/empty.err && [ \"\$(ls $D | wc -l)\" = $before ]"
nt=$(jq -r 'select(.size_reason == "no_tape") | input_filename' "$D"/item-*.json | sort -u | wc -l)
chk "items without a tape ($nt) carry no size, no size text and no number of centimetres" "[ $nt -gt 0 ] && [ \"\$(jq -c 'select(.size_reason == \"no_tape\") | [.size, (tostring | test(\"cm\"))]' $D/item-*.json | sort -u)\" = '[null,false]' ]"
echo "logged: size reasons $(jq -r '.size_reason // "sized"' "$D"/item-*.json | sort | uniq -c | tr -s ' ' | tr '\n' ',')"

# 5 local
chk "every draft is draft_local, none is posted" "[ \"\$(jq -r .status $D/item-*.json | sort -u)\" = draft_local ]"
chk "the script names no network tool" "! grep -E '(^|[^a-z])(curl|wget|ssh|scp|nc|git push|gh )([^a-z]|$)' scripts/mcv-listing | grep -v '^#' | grep -q ."
rc=0; scripts/mcv-listing draft "$R" --out "$w/groups.json" > /dev/null 2>&1 || rc=$?
chk "groups.json is refused as an output (exit 2) and none exists under $w" "[ $rc = 2 ] && [ -z \"\$(find $w -name groups.json)\" ]"
echo "UNVERIFIED R14b: product pixels inside the eroded matte, background and turntable (R7 not merged); sizes are tape estimates, no ruler check"
[ "$fail" = 0 ] || { echo "FAIL listing"; exit 1; }
echo "PASS listing"
