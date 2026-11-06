#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-mojo}
CPU=${CPU:-$(awk '/Cpus_allowed_list/ {split($2,a,"[-,]"); print a[1]; exit}' /proc/self/status)}
scripts/run-capped.sh "$MOJO" build -O3 -I src -I ../mojo-hashlib-public/src tests/bench.mojo -o .work/bench-after
for round in 1 2 3; do
  for side in before after; do
    [ -x ".work/bench-$side" ] || { echo "FAIL bench: missing .work/bench-$side"; exit 1; }
    echo "$side round=$round cpu=$CPU"
    scripts/run-capped.sh /usr/bin/time -f '%e s %M KB' taskset -c "$CPU" ".work/bench-$side"
  done
done
echo 'CPython reference'
scripts/run-capped.sh /usr/bin/time -f '%e s %M KB' taskset -c "$CPU" python3 -I tools/bench_ref.py
