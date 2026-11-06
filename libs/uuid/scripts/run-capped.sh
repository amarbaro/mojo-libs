#!/usr/bin/env bash
set -euo pipefail
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- timeout 120 "$@"
