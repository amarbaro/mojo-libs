# Lane U4 report: `quantize --pure`

Branch `lane-u4`. Code commits `0c10572` (feat: all 8 types, scalar) and `56a6d1a` (perf: K-quants one
sub-block per SIMD lane). Gate: `tests/u4-gate.sh` -> **PASS 11/11**, exit 0.

## Gate output (full run, last)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
     Q8_0: 0.59 s 60480 KB (oracle 0.92 s 1026708 KB)
ok   Q8_0-identical
     Q4_0: 0.46 s 52228 KB (oracle 0.74 s 960224 KB)
ok   Q4_0-identical
     Q4_K: 0.61 s 52244 KB (oracle 1.38 s 977112 KB)
ok   Q4_K-identical
     Q6_K: 0.65 s 60284 KB (oracle 1.24 s 1026084 KB)
ok   Q6_K-identical
     Q2_K: 0.71 s 52528 KB (oracle 1.36 s 960136 KB)
ok   Q2_K-identical
     Q2_0: 0.55 s 41852 KB (oracle 0.79 s 922656 KB)
ok   Q2_0-identical
     TQ1_0: 0.66 s 52084 KB (oracle 0.89 s 960224 KB)
ok   TQ1_0-identical
     TQ2_0: 0.48 s 52280 KB (oracle 0.78 s 960116 KB)
ok   TQ2_0-identical
PASS 11/11
```

## Files under `src/`

| file | LOC | what |
|---|---|---|
| `src/quantize.mojo` | 272 | CLI + driver: type choice and block-size fallbacks, loader tensor order, KV order, header, slab streaming, parallel row quantize |
| `src/gguf/quants.mojo` | 538 | block layouts, `quantize_row` for the 8 types (+ F16 for the unusual-shape fallback), SIMD-lane K-quant fits |

Reuses `gguf.model` (reader, `Out`, `open_fd`, `pread_into`) untouched.

## Wall + RSS (gate lines; oracle = pinned llama-quantize, 16 threads)

| type | ours | oracle |
|---|---|---|
| Q8_0 | 0.59 s / 60 MB | 0.92 s / 1027 MB |
| Q4_0 | 0.46 s / 52 MB | 0.74 s / 960 MB |
| Q4_K | 0.61 s / 52 MB | 1.38 s / 977 MB |
| Q6_K | 0.65 s / 60 MB | 1.24 s / 1026 MB |
| Q2_K | 0.71 s / 53 MB | 1.36 s / 960 MB |
| Q2_0 | 0.55 s / 42 MB | 0.79 s / 923 MB |
| TQ1_0 | 0.66 s / 52 MB | 0.89 s / 960 MB |
| TQ2_0 | 0.48 s / 52 MB | 0.78 s / 960 MB |

Wall is noisy by +-0.2 s between runs (page cache, 16 threads on 8 cores); every row beat the oracle in
every run. Peak RSS is two 16 MiB slabs plus per-worker scratch; the loader mmap is what costs the oracle 1 GB.
Single thread Q4_K: 7.88 s scalar -> 2.10 s with SIMD lanes (Q2_K 2.00 s, Q6_K 1.79 s).

## What was hard

1. **FMA.** Mojo's default `--fp-mode contract=fast` fuses `a*b + c`; the oracle's `ggml-base` is plain
   baseline SSE2 with no FMA. The first build was identical for Q8_0 and Q2_0 (products feed `roundf`, no add)
   and wrong in 12 blocks of one Q4_0 tensor: `x*id + 8.5f` came out 2.9999998 fused, 3.0 unfused. The gate's
   build line has no flag, so every product is wrapped in `llvm.arithmetic.fence` (`fence`/`m`/`vm`), also the
   argument of `nint`/`roundf`. Verified in a probe: default build 2, fenced build 3, `contract=off` build 3.
2. **Output order is not input order.** The loader keeps weights in a `std::map` ordered by (layer number, name),
   so `output_norm`, `token_embd`, then `blk.0.*` sorted by name. KV order: input KVs in order with
   `general.quantization_version` and `general.file_type` dropped from their place and appended (version, then
   file type); `split.*` keys dropped.
3. **Fallbacks under --pure.** 896-wide rows are not 256-blocks, so Q4_K -> Q5_0 and Q6_K -> Q8_0 for 145 of 169
   weights, Q2_K/TQ1_0/TQ2_0 -> Q4_0, Q2_0 (block 64) needs none; F16 if not even 32-divisible.
4. **Vectorizing without changing a bit.** The fits are sequential float recurrences per 16/32-element
   sub-block. Sub-blocks of one super-block are independent, so lane j runs sub-block j (8 lanes Q4_K, 16 Q2_K,
   16 Q6_K): same ops, same order, `if`s become lane masks (`select`), early-exit lanes (`max == min`, all-zero)
   are masked at the end. Sums stay sequential in the loop dimension, which is why this is exact where a
   reduction vectorization would not be.

## Notes

- Only `--pure` is implemented (mixing logic of llama-quantize without `--pure` is out of scope); other
  invocations print `FAIL quantize: usage ...` and exit 1. Optional 5th arg = thread count (default: logical cores).
- A quantized source tensor whose type would change is refused (`allow_requantize` is not implemented);
  a source already of the target type is copied, as in the C.
- Brain folder `~/Brain/mojo-gguf/` does not exist yet; no Brain note written from this lane.

Repairs: 8 compile/behaviour repair attempts (parallelize API x3, pointer origin cast, InlineArray name,
SIMD literal inference, name shadowing `m`, FMA mismatch); no error reached three attempts.
