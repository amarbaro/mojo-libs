#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-$HOME/Projects/mojo/mojo-nightly/.venv/bin/mojo}
mkdir -p .work/nightly
"$MOJO" --version
scripts/cap.sh "$MOJO" precompile -I src src/csv -o .work/nightly/csv.mojoc
for test in tests/test_golden.mojo tests/test_brute.mojo tests/api.mojo examples/quickstart.mojo; do
  name=$(basename "$test" .mojo)
  scripts/cap.sh "$MOJO" build -O3 -I src "$test" -o ".work/nightly/$name" > ".work/nightly/$name-build.txt" 2>&1 || { head -50 ".work/nightly/$name-build.txt"; echo "FAIL nightly: $test"; exit 1; }
  scripts/cap.sh ".work/nightly/$name"
done
echo 'PASS nightly'
