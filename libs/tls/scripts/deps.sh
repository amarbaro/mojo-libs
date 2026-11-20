#!/usr/bin/env bash
# The Mojo libraries mojo-tls imports ([tool.mojo] deps in pyproject.toml) are sibling folders in this monorepo: ../aio.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d ../aio/src ]] || { echo "FAIL setup: ../aio/src missing"; exit 1; }
echo "PASS deps"
