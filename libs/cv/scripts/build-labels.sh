#!/usr/bin/env bash
# Build .bin/mcv-labels (src/siglabel.mojo): mojo-faces' ONNX runner, mojo-tokenizers, imkit/mmap as mojo-faces needs them.
set -euo pipefail
cd "$(dirname "$0")/.."
P=${MOJO_PROJECTS:-$HOME/Projects/mojo}; mkdir -p .bin .work/siglip
"${MOJO:-.venv/bin/mojo}" build -O3 -I src -I "$P/mojo-faces/src" -I "$PWD/../imkit/src" -I "$PWD/../mmap/src" -I "$PWD/../tokenizers/src" -I "$PWD/../uregex/src" -I "$PWD/../json/src" -I "$PWD/../gzip/src" \
  src/siglabel.mojo -o "${OUT:-.bin/mcv-labels}" 2> .work/siglip/build.err || { grep -m3 -A3 "error:" .work/siglip/build.err || true; echo "FAIL build: src/siglabel.mojo"; exit 1; }
