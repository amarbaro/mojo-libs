#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-.venv/bin/mojo}
mkdir -p .work/benchmark/tmp
scripts/cap.sh "$MOJO" build -O3 -I src tests/bench.mojo -o .work/benchmark/reader > .work/benchmark/build.txt 2>&1 || { head -50 .work/benchmark/build.txt; echo 'FAIL benchmark: build'; exit 1; }
for mode in stream owned; do
  TMPDIR="$PWD/.work/benchmark/tmp" scripts/cap.sh taskset -c "${BENCH_CPU:-7}" bench-ab --rounds 3 --hash-key rows --metric 'parse' -- env BENCH_MODE="$mode" .work/benchmark/reader ::: env BENCH_MODE="$mode" python3 -I tools/bench_ref.py | tee ".work/benchmark/$mode.txt"
  scripts/bench-run.sh env BENCH_MODE="$mode" .work/benchmark/reader
  scripts/bench-run.sh env BENCH_MODE="$mode" python3 -I tools/bench_ref.py
done
