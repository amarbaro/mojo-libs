# U9 report: legacy GGML/GGMF/GGJT to GGUF (lane-u9, haiku)

Code commit `6f6a2f8`: `src/ggml2gguf.mojo`, `tests/mk-ggml-variants.py`, `tests/u9-parity.sh`, README rows.
This report is the commit after it.

## Gate

`tests/u9-gate.sh` (exit 0, PASS 7/7):

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
ok   ggjt3-f16-identical
ok   ggmf1-f32-identical
ok   ggml-f32-identical
ok   ggjt3-q8_0-refused-like-upstream
PASS 7/7
rc=0
```

Beyond the gate: `tests/u9-parity.sh` (25 cases, script vs ggml2gguf on the same argv):

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
ok   fixtures
ok   ggjt3-f16 default
ok   ggmf1-f32 default
ok   ggml-f32 default
ok   ggjt2-f16 default
ok   ggjt1-f32 default
ok   ggml-f16 default
ok   ggmf1-f16 default
ok   ggjt3-f16-vocab300 default
ok   ggjt2-q8_0 refused
ok   ggjt3-f16 name+desc
ok   ggjt3-f16 empty desc
ok   ggjt3-f16 empty name
ok   ggjt3-f16 gqa 2
ok   ggjt3-f16 gqa 4
ok   ggjt3-f16 gqa 3 refused
ok   ggml-f16 eps 1e-6 ctx 4096
ok   ggmf1-f16 eps=1e-5 -c 512
ok   ggjt3-f16-vocab300 verbose
ok   already GGUF refused
ok   metadata dir not supported
ok   vocab dir not supported
PASS 25/25
rc=0
```

## Files and LOC under src/

| file | lines | note |
|---|---|---|
| `src/ggml2gguf.mojo` | 469 (about 400 without blanks, comments, docstrings) | new; no other src file touched |

## Wall and peak RSS

| input | ggml2gguf | convert_llama_ggml_to_gguf.py | same bytes |
|---|---|---|---|
| 83 MB legacy GGJTv3 F16 (V=8000, E=1024, 4 layers, synthetic) | 0.04 s / 37 MB | 0.22 s / 122 MB | yes (`cmp`) |

The gate fixtures (0.2 to 0.5 MB) were not timed separately.

## Parity: quirks ported on purpose

1. **Dims.** The script swaps the first two legacy dims, then divides the last by the element size, because
   gguf-py's `quant_shape_from_byte_shape` runs on the uint8 byte array for every type, F32 and F16 included.
   A 64x64 F32 `token_embd` is written as dims 16x64. Read from `gguf-dump` on `ggml-f32.gguf`, not from the docs.
2. **Empty strings.** gguf-py `add_string` returns early on an empty value: `--name ""` and `--desc ""` write no
   key, so the KV count is 19 or 18, not 20. Found by a parity failure, fixed in `emit`.
3. **Q8_0.** `64 % 34 != 0` on the first 2-D tensor gives the script's message and exit 1. Nothing is written:
   the plan (names, shapes, checks) runs before the output file opens.
4. **eps.** `float(eps)` then a float32 cast. The byte-identical gates cover the eps bits in the KV.

## Not ported, or differs

- Tensor data past the end of the input: the script writes the short slice, ours fails with exit 1.
- argparse prefix abbreviations (`--cont 512`) are not accepted. `--opt=value` is accepted.
- The script's INFO and WARNING log lines (stderr) are not reproduced; ours prints one `wrote` line.
- `--model-metadata-dir` and `--vocab-dir` print `not supported` and exit 2, as the brief allows.
- No real legacy model exists on this box. All fixtures are synthetic: `.work/oracle/ggml/` (tests/mk-ggml.py,
  the brief's set) and `tests/mk-ggml-variants.py`. Their layout follows the pinned script's reader.

## What was hard

- Quirk 1 looked like a bug in the script. Parity needs it, so it is kept and commented in the source.
- The first parity run passed 24/24 while three cases had missing inputs: both sides refused, and the rule
  "both refuse = match" read that as parity. A spot check of the refusal messages caught it. Each case now
  declares `ok` or `refuse`, and a missing input fails.
- My gate log went into `.work/u9/`, which the gate deletes at start (`rm -rf "$W"`). The empty file looked
  like a gate that printed nothing. Logs now go to `.work/u9-*.txt`, outside the gate directory.
- Mojo 1.1: `String` has no slice syntax (`arg[eq + 1 :]` is rejected), `String(unsafe_from_utf8=Span(...))`
  needs a named list, and `arg = String(... arg ...)` trips the aliasing check. Fixed with temporaries.
- A survey hook blocked the first write of `tests/u9-parity.sh`. The survey (`~/iTools/INDEX.md`,
  `~/Brain/Skills/_index.md`) found no tool that runs argv variants for byte parity against a Python converter.
  The check stays in the repo, following the `tests/u*-gate.sh` convention.

## Repair count

3 repairs: build round 1 (String slicing, rvalue Span), build round 2 (aliasing, docstring capital), parity
round 1 (empty name and description). The harness hole above was fixed before the commit.

## Status

- Gate `PASS 7/7`, parity `PASS 25/25`, both on the committed tree.
- Not merged: left for the orchestrator's merge gate.
- Not run: GPU (CPU only), a real 7B legacy model (none on the box).
