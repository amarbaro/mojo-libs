#!/usr/bin/env bash
# mojo build with the sibling libraries on the include path: scripts/mojo.sh src/app.mojo out/app
set -euo pipefail
cd "$(dirname "$0")/.."
L="${MOJO_LIBS:-$HOME/Projects/mojo}"
[ $# -eq 2 ] || { echo "FAIL usage: scripts/mojo.sh SRC OUT"; exit 2; }
mkdir -p "$(dirname "$2")"
.venv/bin/mojo build -I src -I "$L/mojo-posix/src" -I "$L/mojo-json/src" -I "$L/mojo-toml/src" -I "$L/mojo-systemd/src" \
  -I "$L/mojo-safetensors/src" -I "$L/mojo-gguf-core/src" "$1" -o "$2"
