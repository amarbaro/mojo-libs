# mojo-gguf

GGUF tooling in Mojo: reader/writer, HF safetensors to GGUF conversion, quantizers, and the gguf-py
scripts, each unit gated byte-for-byte against a pinned llama.cpp (`1744c6bde`). Built so far: the oracle,
the gates, U1 (GGUF v3 reader/writer + `gguf-rewrite`) and U3a (safetensors reader + `hf2gguf` for Qwen2); units and status: `docs/PLAN.md`.

## What exists

| path | what |
|---|---|
| `tools/oracle.sh` | reference outputs from pinned llama.cpp: `convert`, `quantize --pure`, `new_metadata`, `dump`; wall + peak RSS |
| `tools/mkoracle.sh HF_DIR NAME` | full reference set for one model into `.work/oracle/NAME/` |
| `tools/gguf-cmp.py REF GOT` | identical-bytes, else KV + tensor table + per-tensor data diff; self-test `tests/gguf-cmp-selftest.sh` |
| `src/gguf/model.mojo` | GGUF v3 LE reader (sliding window, spans per KV, all 13 value types, nested arrays validated) and writer (streams KV payloads and tensor data through one 1 MiB buffer) |
| `src/gguf_rewrite.mojo` | CLI `gguf-rewrite IN OUT [--name STR] [--remove KEY]...`; first stdout line `kv K tensors T alignment A data_offset D`; edits match `gguf_new_metadata.py` byte for byte |
| `tools/type-census.mojo` | tensor-type census over GGUF files (header + tensor table only): count and bytes per type, per file and total; U6 scope |
| `tests/u1-gate.sh` | U1 gate (reader/writer round trip, parse summary, metadata edits), 16 checks |
| `src/st/` | `json.mojo`: cursor JSON reader over one byte buffer; `safetensors.mojo`: mmap'd shards, tensors in the converter's order (shards by file name, tensors by name), `model.safetensors.index.json` cross-check |
| `src/hf2gguf.mojo` | CLI `hf2gguf HF_DIR --outfile OUT --outtype bf16\|q8_0` for Qwen2 (`Qwen2ForCausalLM`, `Qwen2Model`); byte-identical to `convert_hf_to_gguf.py`; every unsupported input is `FAIL hf2gguf: <reason>`, exit 1 |
| `src/hfconv/` | converter pieces: `qwen2_names.mojo` (HF to GGUF tensor names, swap for the generated map), `naming.mojo` (gguf-py Metadata name heuristics), `quant.mojo` (BF16 / F32 / Q8_0 kernels, bit-exact with gguf-py `quants.py`) |
| `tests/u3-gate.sh` | U3a gate: bf16 and q8_0 identical-bytes against the script, wall + peak RSS vs the oracle |
| `check/u3-naming-check.sh` | `hfconv.naming` vs gguf-py `get_model_id_components` / `id_to_title` / `size_label` on 25 ids x 3 parameter counts |

## Build and gate

```
.venv/bin/mojo build src/gguf_rewrite.mojo -I src -o .work/u1/gguf-rewrite
tests/u1-gate.sh        # PASS 16/16; bf16 rewrite 994 MB: 19 MB peak RSS (runtime floor 17 MB)
```

### hf2gguf (U3a)

```
.venv/bin/mojo build src/hf2gguf.mojo -I src -o .work/u3/hf2gguf
tests/u3-gate.sh        # PASS 5/5; bf16 0.5 s, q8_0 0.5 s, 42 MB peak RSS (script: 17.00 s / 2.31 GB, 6.12 s / 2.10 GB)
```

Plan first (names, types, sizes from the safetensors headers), then header + KVs + tensor infos, then each tensor
streamed through the kernels; consumed source pages are handed back with `madvise(DONTNEED)`. The pre-tokenizer
name comes from the regex in `tokenizer.json`, not from the script's hash of an HF-tokenizers run: the table
(`QWEN2_RE`) has one row, and an unknown pre-tokenizer is a FAIL. Not ported yet, all FAIL loudly: other
architectures, rope scaling, MoE keys, `head_dim`, F16 fallback for rows not divisible by 32, source dtypes
other than BF16/F16/F32, sentence-transformers pooling, named chat templates, tokenizers without `tokenizer.json`.
Mojo refuses a module that imports a package of its own name, so the helpers are `src/hfconv/`, not `src/hf2gguf/`.

Layout rules the writer follows: tensor sizes come from the input's own offsets (no quant table);
output offsets are the running sum of spans padded to `general.alignment` (default 32); with no edit a
file with zero tensors is padded after the tensor infos (C writer), with an edit it is not (gguf-py).
Failures print `FAIL gguf-rewrite: <reason>` and exit 1. Report: `exchange/lane-u1-sonnet-report.md`.

## Setup

`.venv` links to mojo-baro's (Mojo 1.1.0). Oracle Python: ComfyUI venv (torch) for the converter,
mojo-baro's venv (numpy) for gguf-cmp. Fixtures: `tools/mkoracle.sh ~/Models/qwen2.5-0.5b-instruct-hf qwen25-05b`
(about 30 s CPU, 3.9 GB).
