#!/usr/bin/env bash
# B8 offline gate (no GPU): the engine adapter and baro_serve against tests/fake_engine, which speaks the engine's
# line protocol. (1) tests/baro_engine.mojo: wire layer, id routing, stop, rejected request, dead engine, Batcher under
# 16 threads, clean shutdown. (2) baro_serve over HTTP: every answer of 3 client counts, batched and serial, equals the
# fake engine's formula for that client's own prompt; SIGINT ends it with exit 0 and no engine left.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/t/fake
scripts/mojo.sh tests/fake_engine.mojo .work/fake_engine 2> .work/t/fake/build.err || { echo "FAIL build: tests/fake_engine.mojo"; cat .work/t/fake/build.err; exit 1; }
scripts/mojo.sh tests/baro_engine.mojo .work/baro_engine 2>> .work/t/fake/build.err || { echo "FAIL build: tests/baro_engine.mojo"; cat .work/t/fake/build.err; exit 1; }
scripts/mojo-baro.sh src/baro_serve.mojo .work/baro_serve 2>> .work/t/fake/build.err || { echo "FAIL build: src/baro_serve.mojo"; cat .work/t/fake/build.err; exit 1; }
rm -rf .work/t/fake/run1 .work/t/fake/run2; mkdir -p .work/t/fake/run1 .work/t/fake/run2
timeout 120 .work/baro_engine "$PWD/.work/fake_engine" "$PWD/.work/t/fake/run1"
echo "1 2 3" > .work/t/fake/prompt.txt; echo "0" > .work/t/fake/ref.txt
FAKE_TOK_US=500 .work/baro_serve --engine "$PWD/.work/fake_engine" --pack fake --run-dir "$PWD/.work/t/fake/run2" --port 0 > .work/t/fake/serve.out 2>&1 &
srv=$!
trap 'kill "$srv" 2>/dev/null || true' EXIT
for _ in $(seq 100); do grep -q '^LISTEN ' .work/t/fake/serve.out 2>/dev/null && break; sleep 0.1; done
port=$(grep '^LISTEN ' .work/t/fake/serve.out | cut -d' ' -f2) || { echo "FAIL start: baro_serve did not listen"; cat .work/t/fake/serve.out; exit 1; }
curl -sf "localhost:$port/health" | grep -q '"status":"ok"' || { echo "FAIL health"; exit 1; }
python3 -I tools/baro_bench.py "$port" .work/t/fake/prompt.txt .work/t/fake/ref.txt 8 2 --fake --clients 1,8,32 --per 4,3,2 | tee .work/t/fake/bench.out | grep -v '^cell'
grep -q '^identity: PASS' .work/t/fake/bench.out || { echo "FAIL identity over HTTP"; exit 1; }
kill -INT "$srv"
rc=0; wait "$srv" || rc=$?
trap - EXIT
[ "$rc" = 0 ] || { echo "FAIL shutdown: baro_serve exit $rc after SIGINT (want 0)"; exit 1; }
! pgrep -f "$PWD/.work/fake_engine" > /dev/null || { echo "FAIL shutdown: fake engine still running"; exit 1; }
echo "PASS baro-fake"
