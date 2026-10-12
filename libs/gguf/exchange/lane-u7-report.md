# Lane U7 report: LoRA adapter converter (branch `lane-u7`)

Verdict: `tests/u7-gate.sh` **PASS 9/9**. Code commit `525718d` (lora2gguf, f16 emitter, extra check, README); this
report is the commit on top, its sha is the last line of the session.

## Gate output (full, final build)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
     a f32: 0.01 s 17324 KB (oracle 7.21 s 1210784 KB)
ok   a-f32-identical
     a bf16: 0.01 s 17784 KB (oracle 4.03 s 1212840 KB)
ok   a-bf16-identical
     a q8_0: 0.01 s 17996 KB (oracle 3.85 s 1213004 KB)
ok   a-q8_0-identical
     b f32: 0.01 s 16320 KB (oracle 3.79 s 1212320 KB)
ok   b-f32-identical
     b bf16: 0.01 s 16504 KB (oracle 3.68 s 1212684 KB)
ok   b-bf16-identical
     b q8_0: 0.01 s 17092 KB (oracle 3.56 s 1212660 KB)
ok   b-q8_0-identical
PASS 9/9
```

Extra check (`tools/lora-extra-check.sh`, adapter `Qwen-Foo-lora-v2` the gate's adapters do not cover):

```
ok   extra-f32-identical
ok   extra-f16-identical
ok   extra-bf16-identical
ok   extra-q8_0-identical
ok   dir-outfile-name
ok   templated-outfile
PASS 6/6
```

## Files and LOC

| file | LOC |
|---|---|
| `src/lora2gguf.mojo` | 440 |
| `src/hfconv/f16.mojo` | 15 |
| `tools/lora-extra-check.sh` + `tools/mk-lora-extra.py` | 21 + 35 (verifier, not product) |

Reused rather than re-derived: `hf2gguf` (`Gw`, `dropped`, `sampling`, `find_hparam`, `first_element`), `hfconv`
(`components`, `id_to_title`, `size_label`, `qwen2_name`, `emit_f32/bf16/q8_0`), `st` (`Shard`, `StTensor`,
`dtype_code`, `Json`), `gguf.model` (`Out`, `pad_to`). The U2 `tensor_lookup` table was not needed: Qwen2 names come
from `hfconv.qwen2_names`, as in hf2gguf. `st.Checkpoint` was not reused: it globs `model*.safetensors` and sorts
tensors by name, the adapter file is one `adapter_model.safetensors` taken in offset order.

## Wall + peak RSS (this build vs the script's, from the gate)

```
a f32: 0.01 s 17324 KB (script 7.21 s 1210784 KB)    b f32: 0.01 s 16320 KB (script 3.79 s 1212320 KB)
a bf16: 0.01 s 17784 KB (script 4.03 s 1212840 KB)    b bf16: 0.01 s 16504 KB (script 3.68 s 1212684 KB)
a q8_0: 0.01 s 17996 KB (script 3.85 s 1213004 KB)    b q8_0: 0.01 s 17092 KB (script 3.56 s 1212660 KB)
```

Peak RSS is the 1 MiB staging buffer plus the mapped adapter (4.3 MB / 3.3 MB) plus runtime floor; the script's
1.2 GB is torch + the base model class.

## What was hard

- The output is not what the script's structure suggests: `lora_b` has last dim = rank (4, 8), so under q8_0 gguf-py
  `quantize` raises `QuantError` and the tensor silently becomes F16 (the oracle shows Q8_0 `lora_a`, F16 `lora_b`).
  Needed a bit-exact F16 emitter (`hfconv/f16.mojo`), not in the merged quant set.
- `general.*` come from the adapter directory, not the base, and `get_total_parameter_count` negates the total when a
  lora pair exists, so no `general.size_label` is computed and `components` runs with `total_params < 0`
  (`naming.mojo` already carried that branch). `general.file_type` is absent because `set_gguf_parameters` is
  overridden.
- Tensor order: the script iterates `safetensors` keys, which are in data-offset order (checked with a hand-built file
  whose header order differs; not name order). Norm tensors are yielded while iterating, lora pairs only after, so
  norms come first in the output.
- The script cannot be run with `python -I` (it imports `conversion` from its own directory).

## Not ported (FAIL with a message, never a guess)

README.md model-card frontmatter in the adapter dir, `invocation_string` without `alora_invocation_tokens` (needs the
tokenizer), no `--base` / `--base-model-id` (hub download), `--outtype auto` (the script itself dies with
`AttributeError: 'LoraTorchTensor' object has no attribute 'dim'`, verified), non-Qwen2 base architectures,
adapters above 2-D (conv/stacked).

## Repair count

0 compile-error repairs (built first try; only warnings, cleaned). 1 oracle invocation fix (`-I`). No failure file.
