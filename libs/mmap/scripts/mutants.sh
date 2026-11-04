#!/usr/bin/env bash
# Each mutant changes one line of src; the gate must FAIL on every one (a surviving mutant means a blind gate).
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-.venv/bin/mojo}
f=src/mmap/mmap.mojo; killed=0; n=0
while IFS='|' read -r from to; do
  n=$((n+1)); cp $f .work/orig.mojo
  grep -qF "$from" $f || { echo "FAIL mutant $n: pattern not found: $from"; exit 1; }
  sed -i "s|$from|$to|" $f
  if "$MOJO" build -I src tests/cases.mojo -o .work/mutant 2>/dev/null && CASES=.work/mutant scripts/check.sh >/dev/null 2>&1; then
    echo "SURVIVED mutant $n: $from -> $to"
  else killed=$((killed+1)); fi
  cp .work/orig.mojo $f
done <<'M'
Int32(1), fd, Int64(0)|Int32(2), fd, Int64(0)
Int64(0), Int32(2)))|Int64(0), Int32(1)))
var prot = 3 if write else 1|var prot = 1
M
echo "mutants: $killed/$n killed"
[ "$killed" -eq "$n" ] || { echo "FAIL mutants"; exit 1; }
