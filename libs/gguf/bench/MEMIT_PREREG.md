# MEMIT bake prereg (frozen 2026-10-26, before the first run)

Claim: facts edited into `ffn_down` (MEMIT, closed form, exact rank N), shipped as a LoRA adapter through
`lora2gguf`, merged with `llama-export-lora` and quantized with `llama-quantize`, are recalled by stock
llama.cpp from the Q4_K_M file. The rest of the model stays intact.

Instrument: `tests/memit-gate.sh`. Model: Qwen2.5-0.5B-Instruct (a local Hugging Face checkout; the machine path is not recorded here).
Facts: `tools/memit_facts.py --n 200 --seed 0`, invented subjects with real-word targets. Scoring: llama.cpp
greedy decoding, raw completion (no chat template). A prompt counts when the generated text, stripped, starts with
the target word.

| metric | bf16 merged | Q4_K_M merged |
|---|---|---|
| edit recall (200) | >= 90 % | >= 80 % |
| paraphrase recall (400) | >= 60 % | >= 50 % |
| neighbourhood accuracy drop vs same-type base | <= 2 pts | <= 3 pts |
| llama-perplexity, held-out text, vs same-type base | <= +2 % | <= +2 % |

- Mutant: the same adapter with lora_B = 0. Edit recall must be <= 5 % and the gate must FAIL.
- Kill: bf16 edit recall < 70 % or perplexity > +5 %. Verdict written, lane stops.
- Scale probe after a pass: N = 1000, reported, not gated.
- Hyperparameters fixed here, not tuned on the gate: layers 3-7, lambda 1.5e4 (MEMIT's mom2 weight), 25 Adam
  steps at lr 0.5 on the value delta, 5 random prefixes per key, covariance from 20k tokens of
  `.work/oracle/l1-ppl.txt`. Any change after the first scored run is an amendment: it annotates the verdict and
  never flips it.

## Results (2026-10-26, first and only scored run: KILLED)

`tests/memit-gate.sh` FAIL 4/11, receipt `.work/memit/receipt.txt`. 200 facts, bake 246 s (value loss 0.011).

| | edit | paraphrase | neighbours | perplexity |
|---|---:|---:|---:|---:|
| bf16 base | 0.000 | 0.035 | 0.470 | 3.2700 |
| bf16 edited | **0.505** (band 0.90) | **0.360** (0.60) | 0.4975 (drop -0.03, ok) | 3.2829 (+0.39 %, ok) |
| Q4_K_M base | 0.000 | 0.045 | 0.380 | 3.2340 |
| Q4_K_M edited | **0.455** (0.80) | **0.305** (0.50) | 0.5075 (ok) | 3.1713 (-1.9 %, ok) |
| R = 0 mutant | 0.000 both | | | |

Verdict: KILLED by the kill rule (bf16 edit recall 0.505 < 0.70). The edits are real (0 -> 0.505, the mutant stays
at 0) and harmless (perplexity and neighbours inside the bands). They are too weak, and Q4_K_M keeps 90 % of the bf16 recall.
Suspected cause, not measured: the value delta was fit to reach the target at layer 7's output (loss 0.011), but
the five layer edits are applied without MEMIT's re-measurement of the residual between layers, and each key is a
5-prefix average, so the delivered residual falls short of the fitted one. A follow-up is a new prereg, not an
amendment of this one.

