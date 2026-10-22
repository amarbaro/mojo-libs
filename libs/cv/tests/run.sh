#!/usr/bin/env bash
# tests/run.sh [--bench] [CASES.txt...]: build ours, make the fixtures, run every case row through ours and the
# cv2 oracle on the same .mcv inputs and compare with the tolerance written in the row. --bench times 1080p rows,
# --bench-all every row, --md FILE writes the timing tables.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${MCV_PY:-$HOME/iTools/video/camera-motion/v/bin/python}
mkdir -p .bin .work tests/fixtures
if [ ! -x .bin/mojo-cv ] || [ -n "$(find src -newer .bin/mojo-cv -name '*.mojo' | head -1)" ]; then
  .venv/bin/mojo build -O3 -I src src/main.mojo -o .bin/mojo-cv 2>.work/build.log || { tail -30 .work/build.log; echo "FAIL build: see .work/build.log"; exit 1; }
fi
[ tests/fixtures/.made -nt tools/oracle_cv2.py ] || { "$PY" -I tools/oracle_cv2.py --fixtures tests/fixtures && touch tests/fixtures/.made; } || { echo "FAIL fixtures"; exit 1; }
flags=(); cases=()
while [ $# -gt 0 ]; do
  case "$1" in
    --md) flags+=("$1" "$2"); shift 2;;
    --*) flags+=("$1"); shift;;
    *) cases+=("$1"); shift;;
  esac
done
[ ${#cases[@]} -gt 0 ] || cases=(tests/cases/*.txt)
exec "$PY" -I tools/oracle_cv2.py --suite "${flags[@]}" "${cases[@]}"
