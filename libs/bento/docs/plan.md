# Plan: mojo-bento, BentoML's serving core and packaging as a Mojo library

Source: `~/Downloads/BentoML-main.zip` (Apache-2.0, 1155 files). Port of ideas and behaviour, with attribution in
`NOTICE`; Python-only machinery (decorator reflection, pydantic, framework adapters, gRPC, BentoCloud, k8s) is out.
First workload: the mojo-baro LLM engine (`~/Projects/mojo/mojo-baro/serve/`).

## Shape

```
service.toml -> Service (endpoints registered by name)
  B1 HTTP/1.1 server: epoll accept/read loop, keep-alive, worker pool       (mojo-posix)
  B2 endpoints: trait Endpoint (comptime name), JSON in/out, errors -> 4xx/5xx (mojo-json)
  B3 adaptive batcher: CorkDispatcher + linear-cost Optimizer, injectable clock
  B4 /healthz /readyz /metrics (prometheus text), sd_notify ready           (mojo-systemd)
  B5 model store: name:tag -> dir, safetensors/gguf by path                 (mojo-safetensors, mojo-gguf-core)
  B6 SSE streaming endpoint
  B7 bento build DIR / bento serve DIR: binary + service.toml + model refs + systemd unit
  B8 mojo-baro adapter: batched /generate + /v1/chat/completions
```

## Items

| Item | Lane | LOC | Gate (oracle diff, never weakened) |
|---|---|---|---|
| B1 server | A | 400 | 40 raw HTTP cases (pipelined, keep-alive, bad request line, body limits) vs Python h11 parse + http.server |
| B2 endpoints | A | 250 | same service in BentoML (tools/ oracle): byte-equal JSON + status, 30 cases |
| B4 health/metrics | A | 150 | prometheus_client.parser accepts; live Type=notify unit reaches active |
| B6 SSE | A | 120 | framing vs BentoML SSE; reassembly equal |
| B3 batcher | B | 300 | port of `_internal/marshal/dispatcher.py`: replayed arrival traces, fake clock -> same batch sizes + waits as the Python dispatcher |
| B5 model store | B | 200 | list/get/delete vs BentoML store layout on a fixture |
| B8 baro adapter | B | 300 | 1/8/32 clients: batched throughput >= unbatched, greedy outputs identical |
| B7 build/serve | boss, after merge | 350 | clean-VM `bento serve dir` answers the B2 cases |

## Contract between lanes (fixed now; change only via exchange/team.md)
`src/bento/batch.mojo` (lane B) exposes `struct Batcher[In, Out]` with `submit(item: In) raises -> Out` (blocks the
calling worker until its batch runs) and a `run_batch: def(List[In]) raises -> List[Out]` callback. Lane A's worker
pool calls endpoints from N threads; an endpoint that wants batching holds a Batcher. Lane A ships a stub Batcher
(batch of 1) until B's merges.

## Rules
- Mojo in `src/`; Python only in `tools/` as oracle (BentoML in `.venv`). Rows in `tests/cases/*.txt`, `tests/run.sh` runs all.
- Bench numbers in commit bodies; GPU only via `gpu-wait run --timeout S`.
- Commits: conventional subject + why body, no attribution trailers.
