# Lane L3 report: latent quality metric (branch `lane-l3`)

Verdict: `tests/l3-gate.sh` **PASS 8/8**, exit 0. Code commit `617dc47` (latent-metric + numpy verifier), README
commit `dcd9c2d`; this report is the commit on top (final sha is the one printed on the last line of the session).
L1 was not started: `docs/briefs/` holds no `l1.md` and `tests/` no L1 gate, so there is no brief or gate to execute
(PLAN.md names the unit; its prereg runs on Qwythos-9B and needs a quantizer-side change nobody scoped).

## Gate output (full)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
ok   json-keys
ok   self-is-exact
     Q4_K {'cos_mean': 0.9827940436159869, 'top1_agree': 0.53125, 'soft_cos_mean': 0.9749507280025868, 'wa_recovery': 0.9921875}
     Q2_K {'cos_mean': 0.8687682338511576, 'top1_agree': 0.4375, 'soft_cos_mean': 0.8168971947451932, 'wa_recovery': 0.9921875}
ok   q4k-beats-q2k
ok   reproducible
     oracle cos_mean 0.982794044 cos_min 0.955803758 n 32, tool cos_mean 0.9827940436159869
ok   cos-matches-oracle
PASS 8/8
exit 0
```

Reference numbers of the brief reproduce: Q4_K 0.982794, Q2_K 0.868768, bf16 vs bf16 1.0.

## Beyond the gate

`tools/l3-verify.py` recomputes all six numeric keys in numpy (f64, gguf-py dequant) from the same dumps; every key
agrees with the tool to 1e-6:

| case | cos_mean | cos_min | top1 | soft_cos_mean | soft_cos_min | wa_recovery |
|---|---|---|---|---|---|---|
| 0.5B bf16 vs Q4_K, 32 prompts (tied) | ok | ok | ok | ok | ok | 0.9921875 = numpy |
| Qwen2.5-7B Q4_K_M vs itself, 2 prompts (untied `output.weight`) | ok | ok | ok | ok | ok | 0.890625 = numpy |

The untied case exists because the gate's model is tied and the `W_out^T W_in` path would otherwise be unexercised.
The numpy oracle first disagreed there (0.0): the 7B has all-zero `token_embd` rows; numpy produced NaN cosines, the
tool scores zero rows 0. The oracle was fixed, not the tool.

## Wall and RSS

```
latent-metric bf16 Q4_K, 32 prompts, whole run incl. both llama.cpp dumps: wall 84.01 s, peak 1489808 KB (tree: the dump child dominates)
same, dumps reused (the part that is ours):                               wall 1.24 s,  peak 54124 KB
numpy re-derivation of the same part (tools/l3-verify.py):                wall 24.64 s, peak 3905220 KB
```

Hot path: the three streamed passes over `token_embd` (151,936 x 896): soft vectors, the Gram, the 256-probe nearest
search. Gram: 4x4 tiles of 16-lane f32 accumulators over 2048-row chunks, totals in f64. Only 256 probe vectors are
solved (`z = (G + lambda I)^-1 W_out[t]`, `e = z^T B`) instead of forming the d x d W_a. Chunk buffers are 2048 x d
f32 (7 MB) plus the transposed copies; nothing holds a whole token matrix.

Gate wall is dominated by `hidden-probe-dump` (79 s per 32-prompt dump on the 0.5B, 10 dumps in the gate): about 15 min.

## Files under src/

| file | LOC (wc -l) |
|---|---|
| `src/latent_metric.mojo` | 514 |

Added outside src: `tools/l3-verify.py` (48), README section.

## What was hard / repair count

Seven repairs, none the same error three times:
1. `out` / `ref` are keywords as argument names (compile).
2. `String` vs `StringSlice` compare, positional `Pointer.__getitem__` (compile).
3. Empty `List[UInt8]` handed to `pread_into` read nothing: "short read" (runtime).
4. `Mat` holds only the fd while `Gguf` closed it at its last named use: the same class twice more
   (a `List` freed after `f64p(G)`, giving G[0] = -2e307 and 0.0 recovery). Fixed with keep-alive uses, as
   `mojo-nightly-lane-builder` warns. Found by printing G00 beside the trace, not by reading code.
5. `splitlines()` is not used on the dump index (it splits tabs); `split("\n")` instead.
6. Oracle zero-row NaN (above).
7. A development switch, `LATENT_METRIC_REUSE=1`, because one dump is 79 s: kept in the product, documented.

Not done: a reference-dump cache. The gate recomputes the bf16 dump for each of Q4_K, Q2_K and the repro run; a cache
keyed by model path + size + mtime + prompts file would cut the gate by about 4 min. Left out as unrequested.
