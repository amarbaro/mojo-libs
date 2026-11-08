#!/usr/bin/env bash
# matrix-local.sh LIB...: the weekly matrix on this machine for the given libraries (libs.txt names), both channels, one
# cell at a time under a memory cap when systemd-run exists. Same commands as matrix.yml: scripts/matrix-cell.sh per cell,
# then scripts/matrix-report.sh. Clones the libraries' committed HEAD from LIBS_DIR (default: the parent of the main checkout, also from a worktree). Nightly uses NIGHTLY_MOJO
# (an installed nightly mojo; unset = matrix-cell installs one per run).
# Results: OUT (default .work/matrix-results): LIB-CHANNEL.{json,log}, status.md, shields/.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); out=${OUT:-$root/.work/matrix-results}; libs=${LIBS_DIR:-$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}
(($#)) || { echo "FAIL args: usage: matrix-local.sh LIB..."; exit 2; }
if [ -n "${NIGHTLY_MOJO:-}" ]; then export NIGHTLY_MOJO; fi
cap=(); command -v systemd-run >/dev/null && cap=(systemd-run --user --scope -q -p MemoryMax=12G -p MemorySwapMax=0 --)
rm -rf "$out"; mkdir -p "$out"
for lib in "$@"; do for ch in stable nightly; do
  MATRIX_SRC=$libs/$lib "${cap[@]}" "$root/scripts/matrix-cell.sh" "$lib" "$ch" "$out"
done; done
printf '%s\n' "$@" > "$out/libs.txt"
"$root/scripts/matrix-report.sh" "$out" "$out" "$out/libs.txt"
cat "$out/status.md"
