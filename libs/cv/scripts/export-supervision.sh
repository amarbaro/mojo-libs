#!/usr/bin/env bash
# export-supervision.sh: generate the standalone mojo-supervision tree from the monorepo copy (plan 2026-11-23, 3.3, G0.5).
# usage: scripts/export-supervision.sh L OUT [SV]   L = mojo-libs checkout, OUT = new directory, SV = mojo-supervision checkout
#        (default: L's sibling). Source is L's HEAD and SV's HEAD (git archive), never a working tree; the SHAs go to OUT.sha.
# Generated (monorepo wins, classes in .work/fs/export-classify.tsv): libs/cv/src/supervision -> src/supervision,
# tools/supervision/drivers -> src/drivers (the 12 dataset entrypoints leave the shipped package),
# tests/supervision/{cases,fixtures,s5,*.mojo,README.md} -> tests/, examples/supervision -> examples/, with the path text
# rewritten (tests/supervision/ -> tests/, tools/supervision/ -> tools/, ...). Every other path is standalone-owned and
# copied from SV HEAD (scripts, build and run harness, tools/*.py generators, docs, judge, LICENSE, NOTICE, OFL notice).
# Then OUT is compared with SV's committed tree: exit 0 and "PASS export" when equal, else the differing paths and FAIL.
set -euo pipefail
L=$(readlink -f "${1:?usage: export-supervision.sh L OUT [SV]}"); OUT=${2:?usage: export-supervision.sh L OUT [SV]}
SV=$(readlink -f "${3:-$L/../mojo-supervision}")
[ -d "$L/libs/cv/src/supervision" ] || { echo "BLOCK export: $L/libs/cv/src/supervision missing"; exit 3; }
[ -d "$SV/.git" ] || [ -f "$SV/.git" ] || { echo "BLOCK export: $SV is not a checkout"; exit 3; }
rm -rf "$OUT" "$OUT.src" "$OUT.sv"; mkdir -p "$OUT" "$OUT.src" "$OUT.sv"
lsha=$(git -C "$L" rev-parse HEAD); ssha=$(git -C "$SV" rev-parse HEAD)
git -C "$L" archive "$lsha" libs/cv | tar -x -C "$OUT.src"
git -C "$SV" archive "$ssha" | tar -x -C "$OUT.sv"

gen() {  # gen PATH-under-libs/cv -> destination path, or nothing when not generated
  case $1 in
    src/supervision/*) echo "$1";;
    tools/supervision/drivers/*) echo "src/drivers/${1#tools/supervision/drivers/}";;
    tests/supervision/cases/*|tests/supervision/fixtures/*|tests/supervision/s5/*|tests/supervision/README.md) echo "tests/${1#tests/supervision/}";;
    tests/supervision/*/*) ;;
    tests/supervision/*.mojo) echo "tests/${1#tests/supervision/}";;
    examples/supervision/*) echo "examples/${1#examples/supervision/}";;
  esac
}
owned() {  # standalone path not produced by the export
  case $1 in
    src/drivers/judge_*) return 0;;
    src/supervision/*|src/drivers/*|tests/cases/*|tests/fixtures/*|tests/s5/*|tests/README.md|examples/*) return 1;;
    tests/*/*) return 0;;
    tests/*.mojo) return 1;;
  esac
  return 0
}
n=0
cd "$OUT.src/libs/cv"
while IFS= read -r p; do
  d=$(gen "$p"); [ -n "$d" ] || continue
  mkdir -p "$OUT/$(dirname "$d")"
  if grep -Iq . "$p"; then
    sed -e 's#tests/supervision/#tests/#g; s#tools/supervision/drivers/#src/drivers/#g; s#tools/supervision/#tools/#g' \
        -e 's#scripts/supervision/#scripts/#g; s#examples/supervision/#examples/#g; s#docs/supervision/#docs/#g' "$p" > "$OUT/$d"
  else cp "$p" "$OUT/$d"; fi
  [ -x "$p" ] && chmod +x "$OUT/$d"
  n=$((n + 1))
done < <(find src/supervision tools/supervision/drivers tests/supervision examples/supervision -type f | sort)
cd "$OUT.sv"; m=0
while IFS= read -r p; do
  p=${p#./}; owned "$p" || continue
  mkdir -p "$OUT/$(dirname "$p")"; cp -p "$p" "$OUT/$p"; m=$((m + 1))
done < <(find . -type f | sort)
printf 'mojo-libs %s\nmojo-supervision %s\n' "$lsha" "$ssha" > "$OUT.sha"
echo "export: $n generated from mojo-libs $lsha, $m standalone-owned from mojo-supervision $ssha"
cd "$OUT/.."
if d=$(diff -qr "$OUT" "$OUT.sv"); then rm -rf "$OUT.src" "$OUT.sv"; echo "PASS export: equal to mojo-supervision $ssha"
else echo "$d" | sed "s#$OUT.sv#SV#g; s#$OUT#EXPORT#g" | head -40; echo "FAIL export: $(echo "$d" | wc -l) paths differ from mojo-supervision $ssha"; exit 1; fi
