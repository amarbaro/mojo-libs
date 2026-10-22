#!/usr/bin/env bash
# scripts/mojo.sh plus mojo-baro's tokenizer (serve/), minja and uregex: scripts/mojo-baro.sh SRC OUT
set -euo pipefail
cd "$(dirname "$0")/.."
L="${MOJO_LIBS:-$HOME/Projects/mojo}"
M="${MOJO_BARO:-$L/mojo-baro}"
[ $# -eq 2 ] || { echo "FAIL usage: scripts/mojo-baro.sh SRC OUT"; exit 2; }
mkdir -p "$(dirname "$2")"
.venv/bin/mojo build -I src -I "$L/mojo-posix/src" -I "$L/mojo-json/src" -I "$L/mojo-toml/src" -I "$L/mojo-systemd/src" \
  -I "$L/mojo-safetensors/src" -I "$L/mojo-gguf-core/src" -I "$M" -I "$M/serve" "$1" -o "$2"
