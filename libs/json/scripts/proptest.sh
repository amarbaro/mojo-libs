#!/usr/bin/env bash
# Print the path of proptest's src/ for the property smoke step: $PROPTEST, else the sibling library in this monorepo.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n ${PROPTEST:-} ]]; then echo "$PROPTEST"; exit 0; fi
[[ -d ../proptest/src ]] || { echo "FAIL setup: ../proptest/src missing" >&2; exit 1; }
echo "$(cd ../proptest/src && pwd)"
