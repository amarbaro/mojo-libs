#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CASES:?FAIL setup: set CASES to the built case runner}"
D=${CHECK_DIR:-.work/check}
mkdir -p "$D"
if ! systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 120 "$CASES" > "$D/results.txt" 2>&1; then
  cat "$D/results.txt"
  echo 'FAIL check: Mojo fixture replay'
  exit 1
fi
cat "$D/results.txt"
echo 'PASS all'
