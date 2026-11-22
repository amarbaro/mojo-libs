#!/usr/bin/env bash
# CI entry: the full offline gate, then the precompiled package. MOJO=path runs both with that compiler outside pixi
# (pixi's env would hand a nightly compiler the pinned release's runtime libraries: link errors).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${MOJO:-}" ]; then
  # the oracle still needs pixi's python (its expat is the reference; the runner's system expat differs on 2 of 2019 docs)
  py=$(pixi run python3 -c 'import sys; print(sys.executable)' | tail -1) || { echo "FAIL setup: pixi python"; exit 1; }
  PATH="$(dirname "$py"):$PATH" bash tools/gate.sh
  mkdir -p .work && "$MOJO" precompile -I src src/xmojo -o .work/xmojo.mojoc
else
  pixi run gate
  pixi run build
fi
