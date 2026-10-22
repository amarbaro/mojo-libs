#!/usr/bin/env bash
# run3d.sh: build the L3D CLI, then run every tests/cases3d/*.txt row against the numpy oracle.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${PY:-$HOME/iTools/video/camera-motion/v/bin/python}
mkdir -p .bin .work
.venv/bin/mojo build -I src src/mojocv/cli3d.mojo -o .bin/mojo-cv3d 2>&1 | grep -E "error" && { echo "FAIL build: mojo build"; exit 1; } || true
test -x .bin/mojo-cv3d || { echo "FAIL build: no binary"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 "$PY" -I tools/check3d.py tests/cases3d/*.txt
