#!/usr/bin/env bash
# gpu-tree.sh [REV]: the key a GPU gate receipt is bound to, the sha256 of the git tree entries of every path the
# GPU gates exercise (default REV HEAD). scripts/gpu-gates.sh writes it into gpu-gates.receipt; the conda workflow
# refuses a vattn tag whose tree has a different key, so a release always carries a GPU run of exactly its code.
set -euo pipefail
cd "$(dirname "$0")/.."
git ls-tree -r "${1:-HEAD}" -- src tests bench tools scripts/ci.sh scripts/gpu-gates.sh scripts/gpu-tree.sh | sha256sum | cut -c1-64
