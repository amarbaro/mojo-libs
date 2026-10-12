# U3a report: lane u3 (`lane-u3`), safetensors reader + hf2gguf for Qwen2

Result: **PASS 5/5**, gate exit 0. Code commit `6ecff84` (the report commit above it is the branch head).

## Deviations from the brief (read first)

1. **Helpers are in `src/hfconv/`, not `src/hf2gguf/`.** `src/hf2gguf.mojo` cannot import a package named
   `hf2gguf`: `error: module 'hf2gguf' cannot import itself`. The qwen2 name map is
   `src/hfconv/qwen2_names.mojo`, one file, one function, ready to swap for the generated U2 lookup.
2. **The pre-tokenizer name is a table lookup, not a hash.** `tokenizer.ggml.pre` is resolved from the
   `pre_tokenizer` section of `tokenizer.json` (Sequence of Split with the Qwen2 regex, behavior Isolated,
   invert false + ByteLevel add_prefix_space false, use_regex false => `qwen2`). One row (`QWEN2_RE`); an
   unknown pre-tokenizer is `FAIL hf2gguf: pre-tokenizer not in the hf2gguf table`. The rule is sound for a
   vocab family (same regex + ByteLevel flags + same vocab = same script hash); a new row needs the script's
   hash for one model of that family. Proven on one model only.
3. Added `check/u3-naming-check.sh` + probe (outside `tests/` and `tools/`: `tests/u1-gate.sh` diffs both
   against main wholesale, so any added file there fails its gate-files-untouched). Not part of the gate.

## Gate output (`tests/u3-gate.sh`, final run on the committed tree)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
     bf16: 0.28 s 40480 KB (oracle 17.00 s 2308352 KB)
ok   bf16-identical
     q8_0: 0.35 s 40332 KB (oracle 6.12 s 2100288 KB)
ok   q8_0-identical
PASS 5/5
```

Same tree: `tests/u1-gate.sh` PASS 16/16, `tests/gguf-cmp-selftest.sh` PASS 4/4,
`check/u3-naming-check.sh` 75/75 naming lines agree with gguf-py.

## Wall + peak RSS (`/usr/bin/time`, qwen2.5-0.5b-instruct-hf, 942 MB in)

| run | wall | peak RSS | oracle script |
|---|---|---|---|
| bf16 -> 994 MB | 0.28 s (0.29 to 0.58 s over 6 runs; 4 to 8 s stalls twice, btrfs writeback of the previous 994 MB output) | 40 MB | 17.00 s / 2.31 GB |
| q8_0 -> 531 MB | 0.35 s (0.46 to 0.65 s over 6 runs) | 40 MB | 6.12 s / 2.10 GB |

hot path: source safetensors pages stayed resident through the mmap, peak RSS = the model file.
before 0.29 to 0.58 s / 998 MB, after 0.46 to 0.58 s / 42 MB (same-session A/B with release off: 0.46 to 0.49 s, so
the release costs nothing) · input: bf16 and q8_0, both identical-bytes after. Fix: `madvise(DONTNEED)` every
4 MiB consumed and on each tensor's tail (first version released only inside tensors over 4 MiB and left 113 MB
of small tensors resident). Remaining 40 MB: 17 MB runtime floor, 12 MB token strings, 7 MB tokenizer.json bytes.
Per-stage VmRSS: 19 MB after the plan, 32 MB after the tokenizer, then flat through the data.

## Files and LOC under `src/` (`wc -l`)

| file | LOC |
|---|---|
| `src/hf2gguf.mojo` | 583 |
| `src/hfconv/__init__.mojo` | 1 |
| `src/hfconv/naming.mojo` | 309 |
| `src/hfconv/quant.mojo` | 81 |
| `src/hfconv/qwen2_names.mojo` | 55 |
| `src/st/__init__.mojo` | 1 |
| `src/st/json.mojo` | 225 |
| `src/st/safetensors.mojo` | 142 |
| total | 1397 |

## Design

- **Plan, then write.** Safetensors headers give every name, dtype and shape up front, so the plan (final
  names, GGML types, byte sizes, total parameter count for `general.size_label`) is complete before byte 0 of
  the output. Header, KVs, tensor infos, alignment padding, then each tensor streamed in 16384-element slices
  through one 1 MiB staging buffer. The KV count is patched into the header at the end (one `pwrite`).
- **Tensor order** is the script's: shards sorted by file name, tensors sorted by name inside a shard
  (`SafetensorsLocal` sorts), so layer 10 follows layer 1. Multimodal names dropped (`TextModel.filter_tensors`).
- **Types:** 1-D tensors, `*_norm.weight` and anything not `.weight` stay F32; the rest BF16 or Q8_0.
- **Kernels** (`src/hfconv/quant.mojo`, 81 lines): BF16 = float32 bits, NaN forced quiet, round to nearest even
  (a BF16 source is a copy plus the NaN rule, 32 lanes); Q8_0 = per block of 32 `d = max|x| / 127` in f32,
  `id = 1/d`, `q = copysign(floor(a) + floor(2 (a - floor(a))), x)` (the Python converter's `np_roundf`, round
  half away, not llama.cpp's C), `d` stored as f16. Source dtypes BF16, F16, F32.
- **Names:** `general.name`, `basename`, `finetune`, `version`, `size_label` from `_name_or_path` then the
  directory name exactly as gguf-py's `Metadata` heuristics; ASCII only. `src/hfconv/naming.mojo` is the
  longest file (309 lines) because the script's regexes are hand-matched.
- **Tokenizer:** vocab padded to `vocab_size` with `[PAD<i>]` (UNUSED), added tokens override flags from
  `tokenizer_config.json`, CONTROL when special or `<|...|>`-shaped, USER_DEFINED otherwise; merges streamed
  (string or pair form); special ids from `tokenizer_config.json` token contents matched against the
  `tokenizer.json` added tokens, then `config.json`; first writer wins, in that order.
- **JSON** (`src/st/json.mojo`, 225 lines): values are byte offsets into one buffer, nothing is built;
  `member`/`element` walk containers. tokenizer.json (6.7 MB) costs its bytes plus the strings decoded.

## What was hard

- Reading the converter. The tensor order, the KV order and the special-token order are implicit in dict
  insertion order across three files (`base.py`, `metadata.py`, `vocab.py`); each had to be read, then checked
  against the oracle's dump before writing.
- Name resolution: `general.name` comes from the directory name through `get_model_id_components`, whose
  regexes needed hand matchers and a differential run to trust (75/75).
- Package naming (deviation 1) and the 113 MB of small-tensor pages the first release logic left resident.

## Repair count

- Compile repairs: 3, none repeated. (1) `module 'hf2gguf' cannot import itself` (design, deviation 1);
  (2) `use of invalidated interior reference` in the size-label normalisation, rewritten over a byte list;
  (3) a stray expression of mine in `qwen2_names.mojo`.
- Gate repairs: 0 (bf16 and q8_0 identical-bytes on the first build that compiled).
- One unrequested rework for memory (998 MB -> 42 MB), commit `18ed070`.
- `.work/u3-failure.md`: not written.

## Not done (all FAIL loudly, none silent)

Other architectures; rope scaling, MoE keys, `head_dim`, `is_causal=false`; the script's F16 fallback for rows
not divisible by 32; source dtypes other than BF16/F16/F32; `text_config`, sentence-transformers pooling,
named chat templates, tokenizers without `tokenizer.json`; Qwen3_5 (Qwythos) is the second half of U3 and
has no lane here. `tests/` is frozen, so the gate is the only test; `check/u3-naming-check.sh` is extra.
