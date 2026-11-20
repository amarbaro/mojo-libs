#!/usr/bin/env bash
# Link the Mojo libraries bento imports ([tool.mojo] deps in pyproject.toml) into lib/ from their sibling folders in this monorepo.
# A lib/<pkg> that exists already is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
while read -r pkg lib; do
  [[ -e lib/$pkg ]] && continue
  [[ -d ../$lib/src/$pkg ]] || { echo "FAIL setup: ../$lib/src/$pkg missing"; exit 1; }
  mkdir -p lib && ln -s "../../$lib/src/$pkg" "lib/$pkg"
done <<'LIBS'
aio aio
gguf gguf-core
json json
posix posix
safetensors safetensors
systemd systemd
LIBS
