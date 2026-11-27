#!/usr/bin/env bash
# Proves the baseline JPEG parity gate: each one-constant mutant of the decoder must FAIL it.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
[ "$#" = 1 ] || fail usage 'jpeg_mutants.sh PLANTED_JPEG_DIR (created by tests/stock_planted.sh)'
planted=$(realpath -e -- "$1") || fail setup 'planted fixture directory missing'
px=src/mojocv/_jpeg_pixels.mojo
bl=src/mojocv/_jpeg_baseline.mojo
# name|file|literal before|literal after (every occurrence of "before" is mutated)
mutants=(
  "idct_4433|$px|* 4433|* 4434"
  "idct_12299|$px|a3 * 12299|a3 * 12298"
  "ycc_cr_r|$px|91881 * cr|91900 * cr"  # +-1 is equivalent on 8-bit Cr; 91900 differs only at Cr=+-46
  "ycc_cb_g|$px|-22554 * cb|-22555 * cb"
  "upsample_h3|$px|_center(ch, other, i, vertical) * 3|_center(ch, other, i, vertical) * 2"
  "upsample_v3|$px|(3*b + a + Int(even_bias[0])) >> 4|(3*b + a + Int(even_bias[0]) + 1) >> 4"
  "restart_dc|$bl|predictors = Array[Int32, 3](fill=0)|predictors = Array[Int32, 3](fill=1)"
)
mkdir -p .work
root=$(mktemp -d .work/jpeg-mutants.XXXXXX)
trap 'rm -rf -- "$root"' EXIT
killed=0
for m in "${mutants[@]}"; do
  IFS='|' read -r name file before after <<<"$m"
  n=$(grep -cF -- "$before" "$file" || true)
  [ "$n" -ge 1 ] || fail "$name" "anchor missing in $file"
  tree="$root/$name"
  mkdir -p "$tree"
  cp -r src tests "$tree/"
  B="$before" A="$after" perl -0pi -e 's/\Q$ENV{B}\E/$ENV{A}/g' "$tree/$file"
  cmp -s "$file" "$tree/$file" && fail "$name" 'mutation not applied'
  if bash "$tree/tests/jpeg_baseline.sh" "$planted" >"$tree/log" 2>&1; then
    fail "$name" 'mutant PASSED the parity gate (gate too loose)'
  fi
  grep -qE 'FAIL (parity|corrupt)' "$tree/log" || fail "$name" "gate failed for an unrelated reason: $(tail -n 1 "$tree/log")"
  printf 'killed %s: %s\n' "$name" "$(grep -m1 FAIL "$tree/log")"
  killed=$((killed + 1))
done
printf 'PASS mutants %d/%d killed\n' "$killed" "${#mutants[@]}"
