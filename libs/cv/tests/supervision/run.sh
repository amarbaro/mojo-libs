#!/usr/bin/env bash
# Run row files against their Mojo binaries. See tests/supervision/README.md.
# Usage: tests/supervision/run.sh [rowfile ...]   (default: tests/supervision/cases/*.txt)
# Env: BUILD_DIR (default build), ORACLE_PY (default .work/oracle-venv/bin/python, else python3; rowdiff is stdlib only)
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIR=${BUILD_DIR:-build}
PY=${ORACLE_PY:-.work/oracle-venv/bin/python}; [ -x "$PY" ] || PY=python3
OUT=${BUILD_DIR:-build}/tests-out
mkdir -p "$OUT"
# The dataset drivers write into build/ds-out (rowds.mojo OUT_ROOT) without clearing it: a stale
# file from an earlier run would land in the next bundle.
rm -rf build/ds-out

if [ $# -gt 0 ]; then files=("$@"); else
  shopt -s nullglob; files=(tests/supervision/cases/*.txt); shopt -u nullglob
fi
if [ ${#files[@]} -eq 0 ]; then
  echo "SUMMARY 0 row files, 0 rows (tests/supervision/cases/*.txt is empty)"
  exit 0
fi

status=0
for file in "${files[@]}"; do
  [ -f "$file" ] || { echo "FAIL $file: no such row file"; status=1; continue; }
  stem=$(basename "$file" .txt)
  bin="$BUILD_DIR/$stem"
  if [ ! -x "$bin" ]; then
    echo "FAIL $file: binary $bin missing (build it first)"; status=1; continue
  fi
  rows="$OUT/$stem.rows"; actual="$OUT/$stem.out"
  grep -v -e '^#' -e '^$' "$file" > "$rows" || true
  if ! "$bin" < "$rows" > "$actual"; then
    echo "FAIL $file: $bin exited non-zero"; status=1; continue
  fi
  "$PY" tools/supervision/rowdiff.py "$file" "$actual" || status=1
done
exit $status
