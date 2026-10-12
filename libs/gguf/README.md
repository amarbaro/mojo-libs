# mojo-gguf

GGUF tooling in Mojo: reader/writer, HF safetensors to GGUF conversion, quantizers, and the gguf-py
scripts, each unit gated byte-for-byte against a pinned llama.cpp (`1744c6bde`). Built so far: the oracle,
the gates, and U1 (GGUF v3 reader/writer + `gguf-rewrite`, this lane); units and status: `docs/PLAN.md`.

## What exists

| path | what |
|---|---|
| `tools/oracle.sh` | reference outputs from pinned llama.cpp: `convert`, `quantize --pure`, `new_metadata`, `dump`; wall + peak RSS |
| `tools/mkoracle.sh HF_DIR NAME` | full reference set for one model into `.work/oracle/NAME/` |
| `tools/gguf-cmp.py REF GOT` | identical-bytes, else KV + tensor table + per-tensor data diff; self-test `tests/gguf-cmp-selftest.sh` |
| `src/gguf/model.mojo` | GGUF v3 LE reader (sliding window, spans per KV, all 13 value types, nested arrays validated) and writer (streams KV payloads and tensor data through one 1 MiB buffer) |
| `src/gguf_rewrite.mojo` | CLI `gguf-rewrite IN OUT [--name STR] [--remove KEY]...`; first stdout line `kv K tensors T alignment A data_offset D`; edits match `gguf_new_metadata.py` byte for byte |
| `tests/u1-gate.sh` | U1 gate (reader/writer round trip, parse summary, metadata edits), 16 checks |

## Build and gate

```
.venv/bin/mojo build src/gguf_rewrite.mojo -I src -o .work/u1/gguf-rewrite
tests/u1-gate.sh        # PASS 16/16; bf16 rewrite 994 MB: 19 MB peak RSS (runtime floor 17 MB)
```

Layout rules the writer follows: tensor sizes come from the input's own offsets (no quant table);
output offsets are the running sum of spans padded to `general.alignment` (default 32); with no edit a
file with zero tensors is padded after the tensor infos (C writer), with an edit it is not (gguf-py).
Failures print `FAIL gguf-rewrite: <reason>` and exit 1. Report: `exchange/lane-u1-sonnet-report.md`.

## Setup

`.venv` links to mojo-baro's (Mojo 1.1.0). Oracle Python: ComfyUI venv (torch) for the converter,
mojo-baro's venv (numpy) for gguf-cmp. Fixtures: `tools/mkoracle.sh ~/Models/qwen2.5-0.5b-instruct-hf qwen25-05b`
(about 30 s CPU, 3.9 GB).
