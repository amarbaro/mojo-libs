# L1 prereg: latent-aware precision on qwen2.5-0.5B (FROZEN 2026-10-12)

Frozen by the commit that adds this file, before any L1 code exists. The bars below are the gate
(`tests/l1-gate.sh`); changing either after a run is a new prereg, not an amendment.

## Question

At no more bytes than llama.cpp's Q4_K_M, can a per-tensor type recipe chosen by our latent metric (L3) keep the
latent geometry (soft embedding, final-norm hidden) closer to bf16 than Q4_K_M does, without worse perplexity?

## Arms (same job, same inputs)

| arm | file |
|---|---|
| reference | `llama-quantize bf16.gguf Q4_K_M.gguf Q4_K_M` (pinned 1744c6bde): 397,807,584 bytes, in `.work/oracle/qwen25-05b/` |
| L1 | our `quantize --pure bf16.gguf OUT Q4_K` plus the committed recipe's per-tensor overrides (`recipes/qwen25-05b.txt`) |

## Data (disjoint)

- Search set: `tests/l3-prompts.txt` (32 lines). The search may read only this set.
- Held-out set: `.work/oracle/l1-heldout-prompts.txt`, GSM8K test questions 200-231, sha256 prefix 944301bedb25d6f2.
  Readable by the lane, so the search log (`exchange/lane-l1-search.log`, committed) must show every metric call and
  its prompt file; the orchestrator reads it before the merge.
- Perplexity text: `.work/oracle/l1-ppl.txt`, GSM8K test items 300-499 as "Question/Answer", sha256 prefix
  4315bf6d79ff4610; pinned `llama-perplexity -c 512`, CPU.

## Bars (all must hold; gate exit 0 only then)

1. Parity: our quantize with `--token-embedding-type`, `--output-tensor-type`, `--tensor-type PATTERN=TYPE` is
   byte-identical to pinned llama-quantize with the same flags (three combinations on bf16, base Q4_K --pure).
2. Bytes: L1 file size <= 397,807,584.
3. Held-out latent: `soft_cos_mean(L1) > soft_cos_mean(Q4_K_M)` and `cos_mean(L1) >= cos_mean(Q4_K_M)`
   (`latent-metric bf16.gguf X held-out`).
4. Perplexity: `ppl(L1) <= ppl(Q4_K_M)` on the text above.

No minimum gain: a strict improvement at equal or fewer bytes passes (Mario 2026-10-09, every percent counts).

## Prediction (frozen)

The gain comes from token_embd and output (the latent steps read both): keeping them at Q6_K/Q8_0 and paying with
mid-layer FFN at Q4_K/Q2_K. Predicted soft_cos_mean gain +0.003 to +0.02 over Q4_K_M; perplexity within 1% either
way. A miss means optimize the search further, not drop the unit.

## Ladder

0.5B first (this prereg). Qwythos-9B (bf16 HF on disk) follows as its own prereg once this passes; Flash only as a
transferred recipe (no bf16 source here).
