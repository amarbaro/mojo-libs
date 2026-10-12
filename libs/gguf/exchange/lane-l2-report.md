# L2 report: latent data baked into a GGUF (`lane-l2`)

Result: **PASS 7/7**, gate exit 0, on the merged branch (`e549030`: lane-l2 + main at `1779698`).
Code commit `b60b0a4` (tool + README). Merge commits `198272f`, `e549030`.

## Gate output (`tests/l2-gate.sh`, run on `e549030`)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
ok   bake-readback
ok   rebake-idempotent
     latent beta 638.96314 median 0.4505921 w_a 896x896
ok   show
ok   llama-cpp-loads
PASS 7/7
gate rc=0
```

## What it does

- `gguf-latent bake IN OUT --wa W.f32 --beta B --row-median M` writes IN's KV in order, then appends
  `latent.version` (u32 1), `latent.beta` (f32), `latent.embd_row_median` (f32), `latent.w_a` (f32 array, d*d,
  copied from W.f32 byte for byte), `latent.w_a.shape` (u32 array `[d, d]`). Existing copies of those five keys are
  dropped first, so a rebake replaces them. Tensor infos are re-serialized with their original offsets, and the data
  section is copied verbatim from IN's data offset to EOF, through the writer's 1 MiB buffer.
- `gguf-latent show FILE` prints `latent beta B median M w_a DxD` (values as numpy float32 `str`, shortest round-trip
  digits). Missing keys, wrong types, a bad version, or a shape that disagrees with the array length all `FAIL` and
  exit 1.

## Files and LOC under `src/`

| file | lines (`wc -l`) | status |
|---|---|---|
| `src/gguf_latent.mojo` | 153 | new: `bake`, `show`, CLI |

Only this file is new under `src/`. It imports the merged U1 reader and writer (`gguf/model.mojo`: `Gguf`, `Out`,
`MAGIC`, `open_fd`, `T_ARRAY`) and `gguf/fmt.mojo` (`np_float32`), so `model.mojo` is unchanged. `README.md` gained
the build and gate lines and the two table rows.

## Wall and peak RSS

Fixture: `.work/oracle/qwen25-05b/Q4_K.gguf`, 317 MB, 290 tensors. Measured with `/usr/bin/time -f '%e s %M KB'`:

- bake: 1.22 s wall, 18788 KB peak RSS
- show: 0.11 s wall, 19216 KB peak RSS

The runtime floor is about 17 MB (U1 README), so the bake's memory is the streaming buffer plus the header.
Measured on the binary from `b60b0a4`; the tool has not changed since.

## Extra checks beyond the gate

- Replace-then-rebake equals baking the clean file, byte for byte (tested with `--beta 2.5 --row-median 0.75`).
- llama.cpp `llama-cli` loads the baked file and generates text (CPU only, `-st` flag, pinned `1744c6bde`).
- Error paths: IN equal to OUT is refused before the output is opened; a non-square or non-f32 W file is refused; a
  file without latent data makes `show` fail with `missing latent.version`.

## What was hard

- **The U1 writer's `rewrite` could not be reused as is.** It moves `general.architecture` first when editing and
  re-lays the tensor offsets, and L2 needs KV order kept with the latent KV appended. The bake therefore writes the
  header itself on top of the `Out` buffer, leaving the U1 writer untouched.
- **Float parsing.** `Float32(Float64(text))` double-rounds. The readback gate compares against numpy's direct
  `float32(text)`, and it passed for the fixture values. Other inputs could in principle differ in the last bit.
- **The gate failed twice for reasons outside this lane's code.** (1) The load check used `-no-cnv`, which the pinned
  llama-cli rejects; the fix is `-st` (commit `3742de4` on main). (2) That fix commit's trailing comment swallowed
  the `LA=` assignment on line 8 of `tests/l2-gate.sh`; restored in `1779698`. Both are on main, not in this branch's
  code.
- **Gate logs were lost on a failed run.** The gate deletes `.work/l2` at start, so a redirect into that directory
  vanishes. The gate's own per-check output went nowhere; I reran it with output written outside `.work/l2`.

## Repairs

- Compile errors in `gguf_latent.mojo`: 0.
- One warning on the first build (docstring summary style); fixed, rebuilt clean.
- Gate: no change in this lane to `tests/` (frozen). The two gate-level failures above were fixed on main by their
  owner.

## Commit notes

Commit `b60b0a4` carries no `Co-Authored-By` or model attribution, per the repo rules (CLAUDE.md §7 and `common.md`),
which override the harness reminder. The report commit is the final commit of this lane.
