# Brief: mojo-cv optimized for stock assets (2026-11-16)

Boss pane: the one that spawned you (read `HERDR_PANE_ID` of your parent from `herdr agent list`, label `boss`/p1).
Model: Sonnet, effort high. Report back with `herd tell <boss> "DONE assets-cv -> docs/lanes/2026-11-16-assets-cv-report.md"`.

## Goal
Make mojo-cv the image-checking engine for selling assets (ComfyUI images, Blender renders) that feed
`~/Projects/mojo/stock-review` (pass/deny app) and `~/Projects/tools/bulk-stock-tag` (bulk tagging), coordinated from
`~/Projects/AssetsHQ` (read its `CLAUDE.md`, `docs/mistakes-extracted.md`, `~/Brain/SINDEX/assets.md` first: the
rejection reasons there are your requirements). Any improvement to mojo-cv is welcome; speed and correctness both.

## Candidate work (pick by value; measure every one)
1. Stock rejection pre-checks as mojo-cv functions, each with a cv2 oracle gate and planted failures:
   sharpness / focus (variance of Laplacian, Tenengrad), noise estimate, JPEG blockiness, banding in gradients,
   exposure clipping, colour cast, minimum resolution/megapixels, border/watermark/text-like regions.
2. Near-duplicate detection across a batch (perceptual hash dHash/pHash, ORB match) so a set does not upload twins.
3. AI-artifact cues the pass/deny app marks today by hand (hands, text, artifacts): find what CV can flag cheaply.
4. Speed: batch throughput on a 2k+ image library (images/s, RSS), SIMD/parallel where the profile says so.
5. Export: one `mcv-stockcheck` CLI emitting JSON per image that stock-review can read as a sidecar.

## Phase 2: faces (Mario, 2026-11-16)
`~/Projects/mojo/mojo-faces` (package `faces`): SCRFD detection + ArcFace embedding, CPU and GPU runner
(`docs/gpu.md`, `GpuNet`). Import it, do not copy. In `mcv-stockcheck`: `faces: N` and the largest face's share of
the picture, so recognisable people (model release needed, Adobe/Dreamstime refuse without) are flagged before
upload. Gate on the mojo-faces test photos.

## Phase 3: what is in the picture (after phases 1-2 land)
Extend `GpuNet` with the transformer ops a SigLIP image encoder needs (LayerNorm, Softmax, MatMul, GELU, attention),
gated op by op against onnxruntime, then zero-shot labels against the library's category list and near-duplicates by
embedding cosine. Output feeds `category` and `tags` in `~/Projects/AssetsHQ/library/assets.db` (contract
`~/Projects/AssetsHQ/docs/schema.md`). The ops go into mojo-faces' runner (shared), kernels from mojo-baro.

## Research
`paperbrain-ask '<question>'` and `paperbrain-recall` (PaperBrain vault) for image-quality assessment
(no-reference IQA: BRISQUE, NIQE, blur/noise estimators), perceptual hashing, AI-image detection. Note what you used
in `docs/sources.md`.

## Rules
- Skills first: link + read mojo-syntax, mojo-lean, memory-optimization, mojo-cv's own `skills/`, image-ocr.
- Every function gated against cv2/numpy oracle (docs/rules.md: invalid input raises, never a plausible number).
- Commit as work lands, by path; no push. Never open images into context: numbers only.
- Before/after numbers in commit bodies. Report: what landed, numbers, what failed.
