#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CASES:?FAIL setup: set CASES to the built case runner}"
if ! "$CASES" >/tmp/opencode/cases.out 2>&1; then
  cat /tmp/opencode/cases.out; echo "FAIL check"; exit 1; fi
grep -q "PASS cases" /tmp/opencode/cases.out || { cat /tmp/opencode/cases.out; echo "FAIL check"; exit 1; }
echo "scenarios: 1, each twice; failures: 0"
echo "PASS all"