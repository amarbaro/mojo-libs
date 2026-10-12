# mojo-gguf

GGUF tooling in Mojo: reader/writer, HF safetensors to GGUF conversion, quantizers, and the gguf-py
scripts, each unit gated byte-for-byte against a pinned llama.cpp (`1744c6bde`). Nothing is built yet
beyond the oracle and the gates; units and status: `docs/PLAN.md`.

## What exists

| path | what |
|---|---|
| `tools/oracle.sh` | reference outputs from pinned llama.cpp: `convert`, `quantize --pure`, `new_metadata`, `dump`; wall + peak RSS |
| `tools/mkoracle.sh HF_DIR NAME` | full reference set for one model into `.work/oracle/NAME/` |
| `tools/gguf-cmp.py REF GOT` | identical-bytes, else KV + tensor table + per-tensor data diff; self-test `tests/gguf-cmp-selftest.sh` |
| `tests/u1-gate.sh` | U1 gate (reader/writer round trip, parse summary, metadata edits), 16 checks |

## Setup

`.venv` links to mojo-baro's (Mojo 1.1.0). Oracle Python: ComfyUI venv (torch) for the converter,
mojo-baro's venv (numpy) for gguf-cmp. Fixtures: `tools/mkoracle.sh ~/Models/qwen2.5-0.5b-instruct-hf qwen25-05b`
(about 30 s CPU, 3.9 GB).
