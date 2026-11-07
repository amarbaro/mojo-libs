#!/usr/bin/env bash
set -euo pipefail
if command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 120 "$@"
fi
exec timeout 120 "$@"
