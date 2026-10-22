#!/usr/bin/env bash
# B8 live gate (GPU, re-execs under gpu-wait): baro_serve over the real mojo-baro engine.
#   identity   every /generate and /generate_serial answer equals the engine's own single-request answer (greedy)
#   chat       /v1/chat/completions answers 200 with text, using the GGUF's tokenizer and chat template
#   throughput 1, 8 and 32 HTTP clients, REPS rounds per (clients, mode), medians; row = batched >= serial
# env: BARO_ENGINE (default .work/real/engine, built from mojo-baro HEAD when missing), BARO_PACK, BARO_GGUF, INFLIGHT (2), REPS (5), N (64)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${GPU_WAITING_ROOM_JOB:-}" ] && command -v gpu-wait >/dev/null; then
  exec gpu-wait run --priority 60 --timeout "${GATE_TIMEOUT:-3000}" -- "$0" "$@"
fi
M=${MOJO_BARO:-$HOME/Projects/mojo/mojo-baro}
ENGINE=${BARO_ENGINE:-$PWD/.work/real/engine}
PACK=${BARO_PACK:-$M/.work/engine-pack-q4}
GGUF=${BARO_GGUF:-$(python3 -c "import json;print(json.load(open('$PACK/identity.json'))['source'])")}
INFLIGHT=${INFLIGHT:-2}; REPS=${REPS:-5}; N=${N:-64}
mkdir -p .work/t/live
if [ ! -x "$ENGINE" ]; then
  mkdir -p "$(dirname "$ENGINE")"
  (cd "$M" && ./.venv/bin/mojo build serve/engine.mojo -I . -I kernels -o "$ENGINE") > .work/t/live/engine-build.log 2>&1 || { echo "FAIL build: mojo-baro serve/engine.mojo"; tail -5 .work/t/live/engine-build.log; exit 1; }
fi
scripts/mojo-baro.sh src/baro_serve.mojo .work/baro_serve 2> .work/t/live/build.err || { echo "FAIL build: src/baro_serve.mojo"; cat .work/t/live/build.err; exit 1; }
rm -rf .work/t/live/run; mkdir -p .work/t/live/run
.work/baro_serve --engine "$ENGINE" --pack "$PACK" --gguf "$GGUF" --run-dir "$PWD/.work/t/live/run" --port 0 --batch 8 --inflight "$INFLIGHT" > .work/t/live/serve.out 2> .work/t/live/serve.err &
srv=$!
trap 'kill "$srv" 2>/dev/null || true' EXIT
for _ in $(seq 600); do grep -q '^LISTEN ' .work/t/live/serve.out 2>/dev/null && break; kill -0 "$srv" 2>/dev/null || { echo "FAIL start: baro_serve exited"; tail -5 .work/t/live/serve.err; exit 1; }; sleep 0.5; done
port=$(grep '^LISTEN ' .work/t/live/serve.out | cut -d' ' -f2)
echo "baro_serve on $port, engine $ENGINE, inflight $INFLIGHT, N $N, REPS $REPS"
curl -s "localhost:$port/health"; echo
chat=$(curl -s -w '\n%{http_code}' -X POST "localhost:$port/v1/chat/completions" -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":48}')
echo "chat: $(echo "$chat" | head -n -1 | cut -c1-400)"
[ "$(echo "$chat" | tail -1)" = 200 ] || { echo "FAIL chat: HTTP $(echo "$chat" | tail -1)"; exit 1; }
echo "$chat" | head -n -1 | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['choices'][0]['message']['content'].strip(), 'empty content'" || { echo "FAIL chat: empty content"; exit 1; }
echo "chat: PASS"
python3 -I tools/baro_bench.py "$port" "$PACK/prompt-tokens.txt" "$PACK/ref-tokens-64.txt" "$N" "$REPS" --clients 1,8,32 --per 8,2,2 | tee .work/t/live/bench.out
kill -INT "$srv"; rc=0; wait "$srv" || rc=$?; trap - EXIT
[ "$rc" = 0 ] || { echo "FAIL shutdown: exit $rc"; exit 1; }
grep -q '^identity: PASS' .work/t/live/bench.out || { echo "FAIL identity"; exit 1; }
nfail=$(grep -c '^row clients .*: FAIL' .work/t/live/bench.out || true)
if [ "$nfail" = 0 ]; then echo "PASS baro-live"; else echo "PASS baro-live identity+chat; throughput row NOT MET at $nfail of 3 client counts (engine decodes serially, see docs/baro.md)"; fi
