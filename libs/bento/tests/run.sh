#!/usr/bin/env bash
# The gate: build the Mojo test services, run every oracle row against them.
# Usage: tests/run.sh [item ...]   (default: all items). Output of each item: .work/<item>-gate.txt
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.work/oracle-venv/bin/python
[ -x "$PY" ] || { echo "FAIL setup: $PY missing; uv venv .work/oracle-venv && uv pip install -p $PY bentoml h11 prometheus_client httpx"; exit 1; }
mkdir -p .work
pid=""; port=""; bento_port=""; bento_pid=""
trap 'cleanup' EXIT

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

b3() {
  tests/gate-batch-replay.sh
  scripts/mojo.sh tests/batch_threads.mojo .work/batch_threads 2> .work/batch_threads.err || { echo "FAIL build: tests/batch_threads.mojo"; cat .work/batch_threads.err; return 1; }
  timeout 60 .work/batch_threads
}

b5() {
  tests/gate-store.sh
}

# BentoML oracle server (tools/oracle_service.py) on a free port, in its own process group
bento_start() {
  local p=$((20000 + RANDOM % 20000))
  (cd .work && PYTHONPATH=../tools exec setsid "../$PY" -m bentoml serve oracle_service:Oracle --port "$p") > .work/bentoml.out 2>&1 &
  bento_pid=$!
  for _ in $(seq 120); do curl -s "localhost:$p/readyz" > /dev/null && { bento_port=$p; return; }; sleep 0.5; done
  echo "FAIL start: bentoml serve did not answer on $p (.work/bentoml.out)"; exit 1
}
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; [ -z "$bento_pid" ] || kill -- -"$bento_pid" 2>/dev/null || true; }

b2() {
  scripts/mojo.sh tests/b2_service.mojo .work/b2_service 2> .work/b2_service.err || { echo "FAIL build: tests/b2_service.mojo"; cat .work/b2_service.err; return 1; }
  bento_start
  start .work/b2_service
  $PY tools/b2_oracle.py tests/cases/b2.txt "$bento_port" "$port"
}

items=("$@"); [ ${#items[@]} -gt 0 ] || items=(b1 b2 b3 b5)
for it in "${items[@]}"; do
  if "$it" > ".work/$it-gate.txt" 2>&1; then rc=0; else rc=$?; fi  # not a pipeline: servers started inside must be killed by this shell's trap
  cleanup; pid=""; bento_pid=""
  echo "exit $rc" >> ".work/$it-gate.txt"
  tail -40 ".work/$it-gate.txt"
  [ "$rc" = 0 ] || { echo "FAIL $it: exit $rc (.work/$it-gate.txt)"; exit 1; }
done
echo "PASS ${items[*]}"
