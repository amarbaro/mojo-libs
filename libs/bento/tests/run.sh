#!/usr/bin/env bash
# The gate: build the Mojo test services, run every oracle row against them.
# Usage: tests/run.sh [item ...]   (default: all items). Output of each item: .work/<item>-gate.txt
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.work/oracle-venv/bin/python
[ -x "$PY" ] || { echo "FAIL setup: $PY missing; uv venv .work/oracle-venv && uv pip install -p $PY bentoml h11 prometheus_client httpx"; exit 1; }
mkdir -p .work
pid=""; port=""
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT

# start BIN [ARGS]: run a service in the background (not in a subshell, so cleanup sees its pid); sets $port
start() {
  local bin=$1; shift
  rm -f ".work/$(basename "$bin").out"
  "$bin" "$@" > ".work/$(basename "$bin").out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do grep -q '^LISTEN ' ".work/$(basename "$bin").out" 2>/dev/null && break; sleep 0.05; done
  port=$(grep '^LISTEN ' ".work/$(basename "$bin").out" | cut -d' ' -f2) || true
  [ -n "$port" ] || { echo "FAIL start: $bin did not listen"; exit 1; }
}

b1() {
  scripts/mojo.sh tests/echo_server.mojo .work/echo_server 2> .work/echo_server.err || { echo "FAIL build: tests/echo_server.mojo"; cat .work/echo_server.err; return 1; }
  $PY tools/http_oracle.py selfcheck tests/cases/http.txt
  start .work/echo_server
  $PY tools/http_oracle.py check tests/cases/http.txt "$port"
  cleanup; pid=""
}

items=("$@"); [ ${#items[@]} -gt 0 ] || items=(b1)
for it in "${items[@]}"; do
  { "$it"; echo "exit $?"; } 2>&1 | tee .work/$it-gate.txt | tail -40
  rc=$(tail -1 .work/$it-gate.txt | cut -d' ' -f2)
  [ "$rc" = 0 ] || { echo "FAIL $it: exit $rc (.work/$it-gate.txt)"; exit 1; }
done
echo "PASS ${items[*]}"
