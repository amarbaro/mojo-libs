# B8 mojo-baro adapter (current truth)

Batched serving does not beat serial serving on this engine, and cannot: the mojo-baro engine decodes one request at a time.
Measured through HTTP on the real engine, batched throughput is within 0.4% of serial at 1, 8 and 32 clients, and the row
"batched throughput >= unbatched" is met at one of three client counts, by 0.06%. The adapter is correct (greedy answers identical,
chat route works); batching here is admission, not a wider forward pass.

```
HTTP workers --/generate--> Batcher[Call, GenResp] --run_calls--> Engine.generate_batch --lines--> engine process
             --/generate_serial--(lock)------------------------> Engine.generate -------------> (fifo in / fifo out)
             --/v1/chat/completions: GGUF tokenizer + chat template (mojo-baro serve/tokenizer, minja) -> /generate path
engine stdout --reader thread--> per-request Pending (tokens, finish, timings) --> the waiting worker
```

| file | role |
|---|---|
| `src/bento/baro_wire.mojo` | request lines out, event lines in (`ready`, `tok`, `done`, `error`; anything else is a log line) |
| `src/bento/baro.mojo` | `Engine`: spawns the engine (`sh -c 'exec bin <fifo >fifo'`, `BARO_SERVE=1 BARO_PACK=`), one reader thread, id routing, `generate`, `generate_batch`, clean `close()` |
| `src/bento/baro_service.mojo` | `Baro` (engine + Batcher + tokenizer), `BaroApp` (a `Handler`), the endpoints |
| `src/baro_serve.mojo` | the binary: `--engine --pack [--gguf] [--run-dir] [--port] [--batch] [--inflight]` |
| `scripts/mojo-baro.sh` | build with mojo-baro's tokenizer and minja on the include path |

## Routes

| route | |
|---|---|
| `POST /generate` | `{"prompt":[ids] \| "text":..., "n":64, "stop":[ids], "spec":false}`, batched by the Batcher |
| `POST /generate_serial` | same, one request at a time under a lock: the unbatched baseline |
| `POST /v1/chat/completions` | `{"messages":[...], "max_tokens":N}`, greedy, GGUF chat template; 400 without `--gguf` |
| `GET /health`, `/healthz`, `/livez`, `/readyz`, `/metrics` | `Service` built-ins (B4) plus a model line |

Errors: bad input 400; Batcher overload and a dead engine 503 (`baro: engine exited`); the engine's own rejection 400.

## What batching does here

The stack has no multi-sequence forward (mojo-baro A3(c) is not landed; the A3B/A3C pair modes are serial too). A batch reaches
the engine as one burst of request lines, so the engine already holds the next request when one finishes and never idles
between requests. `--inflight 2` lets the next batch be admitted while one runs. Throughput is capped by the device's serial
decode rate, about 143 tok/s on the 7900 XTX for the Q4_0 pack. The row can only be met by a tie.

## Measured

Real engine (mojo-baro `7488cac`), pack `engine-pack-q4` (Qwythos-9B Q4_0, 13-token prompt, tmax 1088), `--batch 8 --inflight 2`,
N = 64 tokens, 5 rounds per mode and client count, after a Batcher warm-up. Receipt: `.work/b8live-gate.txt`.

| clients | serial tok/s (median) | batched tok/s (median) | ratio | row |
|---|---|---|---|---|
| 1 | 143.38 | 142.90 | 0.9967 | FAIL |
| 8 | 143.17 | 143.25 | 1.0006 | PASS |
| 32 | 142.51 | 142.50 | 0.9999 | FAIL |

All 30 rounds: 137.9 to 143.8 tok/s; the one low round is the first batched round at one client (137.90, 4% under serial).
An earlier in-process sweep (no HTTP, 3 rounds) read 144.19 / 143.98 at one client and 143.30 / 142.82 / 143.56
(unbatched / batched / batched with inflight 2) at 32, all within 0.5%. The row is "not demonstrably met": the differences
are inside round-to-round spread, and the sign flips between runs.

## Findings

**Stale reference file.** mojo-baro's `ref-tokens-64.txt` agrees with the engine only for the first 30 of 64 tokens. Engines built
on 10/17 and 10/22 both depart from it at token 31, with speculation on or off, and agree with each other. Identity is
therefore defined against the engine's own first single-request answer; the bench prints the agreement length.

**Dispatcher warm-up.** BentoML's dispatcher starts in four training phases (1, 1, 2, 3 requests) with pessimistic estimates and
corks while the mean queue wait is high. The first live run, without warm-up, measured batched 121.7 and 115.0 tok/s at one
client in rounds 0 and 1 against 144 serial, then 143.4. `baro_bench.py` now takes the Batcher through its training phases
before timing; that removed the slow rounds except the first one above. A service that restarts and meets a lone request
pays this once, as BentoML does.

## Gates

`tests/gate-baro-fake.sh` (`tests/run.sh b8`, no GPU, 25 s): `tests/fake_engine.mojo` speaks the engine protocol.
`tests/baro_engine.mojo` covers the wire layer, id routing, stop sequences, a rejected request, a dead engine, 160 requests in
21 bursts through the Batcher, clean shutdown. Then `baro_serve` over HTTP at 1, 8 and 32 clients, batched and serial: every
answer equals the fake engine's formula for that client's own prompt; SIGINT exits 0 and leaves no engine. The fake rows
print ratios (0.77, 0.99, 0.99) that measure dispatcher overhead against a 0.5 ms/token fake, not the engine.

`tests/gate-baro-live.sh` (`tests/run.sh b8live`, GPU through `gpu-wait`, about 25 min, not in the default list): identity
(every answer of both modes equals the engine's own first single-request answer), chat (HTTP 200, non-empty text), and the
throughput rows above. Its last line says `PASS baro-live` only when every throughput row passes; otherwise it says which
part passed and that the throughput row is not met.

Open: with a multi-sequence forward in the engine (A3(c)), the same gate would measure a real batching gain; nothing in
the adapter would change.
