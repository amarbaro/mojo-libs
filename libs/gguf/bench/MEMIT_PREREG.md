# MEMIT bake prereg (frozen 2026-10-26, before the first run)

Claim: facts edited into `ffn_down` (MEMIT, closed form, exact rank N), shipped as a LoRA adapter through
`lora2gguf`, merged with `llama-export-lora` and quantized with `llama-quantize`, are recalled by stock
llama.cpp from the Q4_K_M file. The rest of the model stays intact.

Instrument: `tests/memit-gate.sh`. Model: Qwen2.5-0.5B-Instruct (HF dir `~/Models/qwen2.5-0.5b-instruct-hf`).
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

## Results
(empty until the run)
