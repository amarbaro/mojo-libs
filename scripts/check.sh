#!/usr/bin/env bash
# Regenerate the table from every library's pyproject.toml; fail if README.md differs (index drift).
# --write updates README.md instead. Needs mojo-toml next to this repo (LIBS_DIR, default: the parent of the main checkout, also from a worktree).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
cap(){ systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 300 "$@"; }
LIBS=${LIBS_DIR:-$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}
M=${MOJO:-$LIBS/mojo-toml-public/.venv/bin/mojo}
cap "$M" build -I "$LIBS/mojo-toml-public/src" tools/gen.mojo -o .work/gen || { echo "FAIL build: tools/gen.mojo"; exit 1; }
.work/gen "$LIBS" libs.txt > .work/table.md || { cat .work/table.md; exit 1; }
awk 'FNR==NR{t=t $0 "\n"; next} /<!-- libs -->/{printf "%s\n%s", $0, t; skip=1; next} /<!-- \/libs -->/{skip=0} !skip' .work/table.md README.md > .work/README.md
if [ "${1:-}" = --write ]; then cp .work/README.md README.md; echo "wrote README.md"; exit 0; fi
diff -u README.md .work/README.md || { echo "FAIL drift: README.md table is stale, run scripts/check.sh --write"; exit 1; }
n=$(grep -c '^| \[' README.md); echo "PASS index: $n libraries"
