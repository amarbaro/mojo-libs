# mcvd: the resident vision daemon (R2a, serialized proof)

Plan: `Brain/mojo-cv/plans/2026-11-23-fullstack-plan.md` 3.2. Placement: `libs/mcvd` (app layer) over `libs/gpunet`, `libs/posix`, `libs/msgpack`.
Direct CLIs keep importing gpunet; the daemon is optional.

```
client --unix socket--> mcvd (one process, one compute owner, poll loop) --> GpuNet per registered model
                         DIR/mcvd.lock (flock, taken before bind)   DIR/mcvd.sock (DIR mode 0700)
```

Run: `gpu-wait run --shared --vram 4 --timeout S --label mcvd -- mcvd DIR NAME=KIND:ARM:PATH ...` (KIND `run` or `text`, ARM 16 or 32).

## Protocol v1 (`src/mcvd/proto.mojo`)

Prefix of 24 bytes (magic `MCVD`, version 1, kind, id u64, header length u32, body length u32, little-endian), msgpack header map, body of `.mcv`
records. Payload at most 64 MiB, header at most 64 KiB, both refused from the prefix before a payload byte is stored. A frame must be whole 5 s
after its first byte (else `timeout`). Status: ok, bad_frame (peer dropped after the reply), unknown_op, unknown_model, busy, timeout, oom, internal.

| op | request | reply |
|---|---|---|
| `ping` | `{op}` | `{status}` |
| `run` | `{op, model, inputs:[{name, shape}]}`, one float32 or int32 record per input | `{status, outputs:[{name, shape}]}`, one float32 record per graph output |
| `siglip_text` | `{op, model}`, one int32 record n x 64 (ids) | one float32 record n x 768 (`text_embeds`), n at most 256 |

Clients keep decode, preprocess, label application and sidecar writers; only the inference call moves to the socket.

## Gate: `tests/serial.sh`

Parity (text and detector bytes equal the direct gpunet run), two interleaved clients, faults (unknown op and model, bad magic, oversized frame,
short frame, hang-up), second instance exit 3, SIGKILL and restart, and a planted mutant daemon. Receipt through `fs-gate.sh`.

## Not yet (R2b, G3.1)

Queue of 32 with `busy`, per-op deadlines, residency budget and least-recent eviction, model keys with a sha256 prefix, SIGTERM drain, forced
termination mid request with card memory back to baseline, `tests/lifecycle.sh`. `proto.mojo` is v1-complete for R2a; the freeze and its hand-over
to the boss (OWNERS.tsv) are the boss's call after R2b.
