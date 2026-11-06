#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
M=${NIGHTLY_MOJO:-$HOME/Projects/mojo/mojo-nightly/.venv/bin/mojo}
mkdir -p .work/nightly
"$M" --version
scripts/run-capped.sh "$M" precompile -I src -I ../mojo-hashlib-public/src src/uuid -o .work/nightly/uuid.mojoc
for test in tests/test_*.mojo examples/quickstart.mojo; do
  name=$(basename "$test" .mojo)
  scripts/run-capped.sh "$M" run -I src -I ../mojo-hashlib-public/src "$test" > ".work/nightly/$name.txt" 2>&1 || { cat ".work/nightly/$name.txt"; echo "FAIL nightly: $name"; exit 1; }
  echo "ok $name"
done
echo 'PASS nightly package, all tests and quickstart'
