#!/usr/bin/env bash
# GPU parity gate: rebuild (scripts/ci.sh), generate cases, run vattn_fwd, compare with the fp64 reference, then write
# gpu-gates.receipt bound to the committed tree (scripts/gpu-tree.sh). Needs a gfx1100 GPU. Commit the receipt: the
# conda workflow publishes a vattn tag only when the receipt's key matches the tagged tree.
# Usage: scripts/gpu-gates.sh   (wrap in `gpu-wait run --vram 4 --timeout 600 --` on a shared box)
set -euo pipefail
cd "$(dirname "$0")/.."
P="src tests bench tools scripts/ci.sh scripts/gpu-gates.sh scripts/gpu-tree.sh"
git diff --quiet HEAD -- $P && [ -z "$(git ls-files --others --exclude-standard -- $P)" ] \
  || { echo "FAIL tree: uncommitted changes under $P; commit first, the receipt names a committed tree"; exit 1; }
bash scripts/ci.sh || { echo "FAIL ci: scripts/ci.sh"; exit 1; }   # fresh binaries of this tree, never a stale .work/run_vattn
uv sync --group oracle || { echo "FAIL setup: uv sync"; exit 1; }
export PATH="$PWD/.venv/bin:$PATH"
cases=()
for c in "129 4 3" "1000 2 2" "4097 2 2"; do
  set -- $c
  d=".work/case-$1-$3"; mkdir -p "$d"
  python3 tools/vattn-ref.py gen "$d" "$1" "$2" "$3" >/dev/null || { echo "FAIL gen: $d"; exit 1; }
  cases+=("$d")
done
bench/parity.sh "${cases[@]}"
M=${MOJO:-.venv/bin/mojo}
{ echo "tree $(scripts/gpu-tree.sh)"; echo "commit $(git rev-parse --short HEAD)"; echo "mojo $($M --version)"
  echo "gfx_target_version $(awk '$1 == "gfx_target_version" && $2 > 0 { print $2; exit }' /sys/class/kfd/kfd/topology/nodes/*/properties)"; echo "date $(date -u +%F)"
  echo "cases ${cases[*]}"; } > gpu-gates.receipt
echo "PASS gpu-gates (receipt: gpu-gates.receipt, commit it)"
