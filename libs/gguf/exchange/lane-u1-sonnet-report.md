# U1 report: lane sonnet (`lane-u1-sonnet`)

Result: **PASS 16/16**, gate exit 0. Code commit `1a7b142`.

## Gate output (`tests/u1-gate.sh`, final run)

```
ok   gate-files-untouched
ok   rewrite-bf16
ok   rewrite-q8_0-py
ok   rewrite-Q8_0
ok   rewrite-Q4_0
ok   rewrite-Q4_K
ok   rewrite-Q6_K
ok   rewrite-Q2_K
ok   rewrite-Q2_0
ok   rewrite-TQ1_0
ok   rewrite-TQ2_0
ok   rewrite-flash-shard1
ok   summary-Q4_K
ok   summary-flash
ok   edit-Q4_K
ok   edit-flash
bf16 rewrite: 0.60 s 18992 KB (994 MB file)
PASS 16/16
```

## Files and LOC (`wc -l`)

| file | LOC |
|---|---|
| `src/gguf/model.mojo` | 297 |
| `src/gguf_rewrite.mojo` | 30 |
| `src/gguf/__init__.mojo` | 1 |
| total under `src/` | 328 |

## bf16 rewrite (994 MB)

| | wall | peak RSS |
|---|---|---|
| byte copy (brief) | 0.38 s | 2.33 GB |
| first version (whole header prefix buffered) | 0.18 s | 49 MB |
| final (sliding window + 1 MiB staging) | 0.16 to 0.60 s over 6 runs | 19 MB |

Runtime floor: the binary run with no arguments peaks at 17 MB, so the writer adds about 2 MB.
Wall is page-cache and btrfs-writeback noise on a 994 MB output (0.16 s on the quiet runs, 0.60 s on
the final gate run); RSS is stable at 18.4 to 21.2 MB.

## Design

- Reader walks the header through a 256 KiB sliding read window. Per KV it records key, type and file
  span `[start, end)`; value payloads are validated by the walk (all 13 types, arrays of strings,
  nested arrays, bounds checks before every skip) and never stored.
- Writer streams KV payloads and tensor data from IN through one 1 MiB staging buffer (`Out`).
- Tensor spans come from IN's own offsets (`next_offset - offset`, last one to EOF), so no
  quant-type size table is needed. Output offsets are recomputed as the running sum of spans padded to
  the alignment, matching `GGUFWriter`. Input offsets must be ascending (else `FAIL`).
- Edit mode mirrors `gguf_new_metadata.py`: `general.architecture` first, `general.name` replaced in
  place (or appended if absent or removed), removed keys dropped, offsets and padding recomputed.

## Design calls worth a reviewer's look

1. **Zero-tensor files.** The C writer (which made the Flash-Next shard) pads after the tensor infos
   even with no tensors; `GGUFWriter` writes no padding there. Both oracles are in the gate, so no-edit
   mode pads (reproduces IN) and edit mode does not (reproduces `edit-flash.gguf`, 10,936,578 bytes,
   not a multiple of 32). One `if len(tensors) > 0 or not edited` in `rewrite`.
2. **Nested arrays are copied verbatim.** `gguf_new_metadata.py` would re-pack them with the innermost
   element type (`field.types[-1]`) and corrupt them; no gate file has one, and byte-preserving is the
   behaviour the no-edit contract asks for.
3. **`--name ""`** is treated as no `--name` (python's `if args.general_name:`).
4. Only GGUF v3 little-endian is accepted; anything else prints `FAIL gguf-rewrite: <reason>` and exits 1.
   A truncated file and a non-GGUF file were checked by hand: both fail with a message, not an abort.

## What was hard

- `external_call["write", ...]` conflicts with the stdlib's own `write` declaration at LLVM lowering
  (`existing function with conflicting signature`). Switched to `pwrite`, which also made output
  offsets explicit. (The `mojo-nightly-lane-builder` table lists `open` and `read` but not `write`.)
- Python's edit semantics are the real spec: the `--remove` order versus `--name` append, the
  architecture-first move, and the empty-tensor padding are only visible by reading `gguf_writer.py`.
- Tried `copy_file_range` for the tensor section: not faster (0.43 to 0.52 s vs 0.16 to 0.43 s on the
  same file, noisy) and no RSS gain, so reverted; not in the commit.

## Repair count

- Compile repairs: 1 (the `write` -> `pwrite` signature conflict). Same error never repeated.
- Gate repairs: 0 (PASS 16/16 on the first build that compiled).
- One unrequested rewrite for memory (49 MB -> 19 MB), commit `1a7b142`.
- `.work/u1-failure.md`: not written.

## Not done

- No unit tests under `tests/` (the brief forbids editing it; the gate is the test).
- Receipts are from `tests/u1-gate.sh` only; the 3 malformed-input checks above were run by hand.
