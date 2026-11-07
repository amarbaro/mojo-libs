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
if [ "${CHECK_DIR:-}" != ".work/mcheck" ]; then
  python3 -c 'import re; m = re.search(r"```mojo\n(.*?)```", open("README.md").read(), re.S); open("'"$D"'/readme_doctest.mojo", "w").write(m.group(1))'
  MOJO=${MOJO:-.venv/bin/mojo}
  if [ -x "$MOJO" ]; then
    systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 120 "$MOJO" build -I src -I ../mojo-hashlib-public/src "$D/readme_doctest.mojo" -o "$D/readme_doctest" > "$D/doctest_build.txt" 2>&1 || { cat "$D/doctest_build.txt"; echo 'FAIL check: README doc-test build'; exit 1; }
    systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 120 "$D/readme_doctest" > "$D/doctest.txt" 2>&1 || { cat "$D/doctest.txt"; echo 'FAIL check: README doc-test run'; exit 1; }
  fi
fi
echo 'PASS all'
