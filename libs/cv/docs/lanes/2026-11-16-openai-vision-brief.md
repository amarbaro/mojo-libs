# Brief: OpenAI vision papers -> asset-vision hub (2026-11-16)

Boss: wXY:p1. Model: Sonnet, effort high. Report: `herd tell wXY:p1 "DONE oaivision-<step> -> <file>"`.

## Why
Our OpenAI paper set on disk is the math release (no CV). Mario wants OpenAI's vision papers studied and in the
asset-vision hub (`~/Brain/Skills/own/asset-vision/`), no new hub.

## Papers (ids from memory: verify each title/id on arXiv before fetching; fix or drop a wrong one, say so)
| paper | candidate id |
|---|---|
| CLIP, Learning Transferable Visual Models From Natural Language Supervision | 2103.00020 |
| Consistency Models | 2303.01469 |
| Improved Techniques for Training Consistency Models | 2310.14189 |
| Simplifying, Stabilizing and Scaling Continuous-Time Consistency Models (sCM) | 2410.11081 |
| Improved Denoising Diffusion Probabilistic Models | 2102.09672 |
| Diffusion Models Beat GANs on Image Synthesis (guided diffusion) | 2105.05233 |
| Hierarchical Text-Conditional Image Generation with CLIP Latents (DALL-E 2) | 2204.06125 |
| Scaling and evaluating sparse autoencoders | 2406.04093 |
| Generative Pretraining from Pixels (iGPT) | not on arXiv: ICML 2020 PDF from openai.com / PMLR |
| Video generation models as world simulators (Sora technical report) | web page, save as text |
Add any OpenAI vision paper the cards point to as directly useful (max 5 more), each with its reason.

## Steps
1. Skills: `paper-study`, `research`, `asset-vision`. paperhub (`. scripts/env.sh`, `PAPERHUB_HTTP=tls`), store as for
   the 207 (`~/Brain/research/papers/pdf/`). Network fetches are papers only.
2. One JSON card per paper, quotes checked by `study-check.sh` (no quotes from memory; mojo-cv rules 17, 18).
3. Add cards + text to `~/Projects/mojo/mojo-cv-papers` (post-commit hook rebuilds neurons); then
   `REFRESH_FORCE=1 ~/iTools/brain/brain-ask/refresh.sh` and prove one `brain-ask --net text` hit per paper family.
4. Hub: new `references/openai-vision.md` (what each paper gives our pipeline: CLIP -> SigLIP tagging and zero-shot
   labels; consistency models -> fast generation; diffusion guidance -> ComfyUI settings; unCLIP -> embedding-space
   edits; SAE -> explaining a flag; iGPT -> pixel priors; Sora -> vidcode), route rows in SKILL.md, `papers.tsv` rows,
   cross-links from `tagging-captioning.md`, `generation-comfyui.md`, `video-vidcode.md`, `build-list.md` where a paper
   changes a ranked build. Keep the hub contract (`_hubs/contract.md`): SKILL.md <= 150 lines, debloated style.
5. `hub-check.sh asset-vision` PASS, `route-test.sh` with 2 new prompts, `skilldex`; commit by path; report
   `docs/lanes/2026-11-16-openai-vision-report.md`.
