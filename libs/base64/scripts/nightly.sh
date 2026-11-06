#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO_NIGHTLY:-$HOME/Projects/mojo/mojo-nightly/.venv/bin/mojo}
mkdir -p .work
"$MOJO" --version
scripts/capped.sh "$MOJO" precompile -I src src/base64 -o .work/base64-nightly.mojoc
for t in tests/test_golden.mojo tests/test_brute.mojo tests/api.mojo examples/quickstart.mojo; do
  scripts/capped.sh "$MOJO" run -I src "$t" || { echo "FAIL nightly: $t"; exit 1; }
done
echo 'PASS nightly'
