#!/usr/bin/env bash
# Dev helper: rewrite tests/limbo_known.txt from the last tests/lim.sh run (only ever shrinks it; run lim.sh first).
set -euo pipefail
cd "$(dirname "$0")/.."
grep '^DIFF' .work/gate/limbo_out.txt | cut -d' ' -f2 | sort > tests/limbo_known.txt
wc -l < tests/limbo_known.txt
