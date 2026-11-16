# Brief: CV research, ~200 latest papers -> supervision skill + neurons (2026-11-16)

Boss pane: wXY:p1. Model: Sonnet, effort high. Sub-assistant: ONE Haiku pane you spawn yourself in herdr
(herdr-ops verified commands: `herdr-start <pane> NAME claude -- --model 'haiku[1m]' --effort low --permission-mode auto`)
for fetching, extracting and card drafting; it reports to you with `herd tell <your pane>`.
Report each step: `herd tell wXY:p1 "DONE cv-research-<step> -> <file>"`.

## Goal (Mario)
Make mojo-cv better for our asset work by studying the latest computer-vision research that fits it, and turn
what is learned into a **supervision skill** used beside mojo-cv (what to build, how to gate it, which numbers to
expect, what fails), plus every paper as neurons in the Brain network.

## Scope: what "fits our purpose"
Stock/asset image quality and selection: no-reference IQA (incl. learned, AIGC-specific IQA), AI-generated image
artifact detection (hands, text, anatomy), aesthetics scoring, near-duplicate / perceptual hashing and embedding
dedupe, zero-shot classification and tagging (SigLIP/CLIP family), captioning/keywording for stock, face detection
and quality, segmentation and granulometry (we have mojo-cv grain + solar filament work), 3D asset quality (mesh /
GLB / texture), efficient GPU inference of small vision models. Prefer 2025-2026, arXiv, with code where possible.

## Steps
1. Tools first: load skills `paper-study`, `research-paper`, `mojo-cv` (repo `skills/`), `mojo-lean`, `herdr-ops`.
   paperhub: `cd ~/Projects/web-apps/paperhub && . scripts/env.sh` (read `docs/study-workflow.md`). Network fetches
   are papers only; never send our data out.
2. Search and select about 200 papers by title/abstract against the scope -> `docs/research/cv-papers.tsv`
   (arxiv id, title, year, topic, why it fits). Fetch PDFs with paperhub into its store, not into mojo-cv.
3. Read: Haiku drafts one JSON knowledge card per paper (method, numbers, code link, verbatim quotes checked by
   `study-check.sh`); you verify a sample of 20 and every card you cite.
4. Neurons: index the cards + full text into the Brain network (paperhub/PaperBrain path, or a small git repo of the
   cards + `repo-net build` + `repo-net hook`); prove with one `brain-ask --net text` query that returns a card.
5. Skill: `~/Brain/Skills/own/cv-supervision/SKILL.md` (via `skill-new.sh`): a ranked list of what mojo-cv should
   build next (with the paper, expected numbers and the gate), the evaluation rules (oracles, planted failures,
   calibration on accepted sets), failure modes, and a route table. Link it into mojo-cv `.claude/skills/` and
   AssetsHQ `.claude/skills/`; run `skilldex`.
6. Also mine our own projects for reusable CV: `~/Projects/kaggle.com/competitions/{filament-segmentation-2026,
   soil-grain-size-from-photos}` (solar filaments, soil grain), mojo-faces, stock-review. **Kaggle data stays in
   Kaggle folders (competition use only, no redistribution): methods and code may move into mojo-cv, never images,
   labels or derived data.** List findings in the skill.
7. Brain note `~/Brain/mojo-cv/2026-11-16-cv-research.md` (synthesis), board line, commits by path, no push.

## Coordinate
`assetscv` (wYQ:p1) builds mojo-cv phases 2-3 now; send it the skill path when step 5 lands. Do not edit
`src/mojocv/stockcheck.mojo` yourself.

## Scope change (Mario, 2026-11-16): one mega skill for the whole visual pipeline
Step 5 becomes **`~/Brain/Skills/own/asset-vision/`** (replaces the planned `cv-supervision`; create with `skill-new.sh`).
It is used along the whole AssetsHQ pipeline: ComfyUI generation, Blender, Gonzales (our renderer,
`~/Projects/imports/Gonzales`), vidcode (video), TRELLIS/3D, stills and photos (`~/Pictures/TAGS` as local calibration),
stock upload, and mojo-cv/mojo-faces as the checking engine.
- **SKILL.md is a short hub** (< 150 lines): when to use, a route table "task -> reference file", the 10 rules that
  never bend, and the pipeline diagram (generate -> render -> check -> pick -> tag -> upload). Nothing else loads by default.
- **`references/` load only when needed**, one file per domain, each with paper citations (arXiv id, claim, number,
  verbatim quote checked by study-check) and what it means for us: `generation-comfyui.md`, `rendering-blender.md`,
  `rendering-gonzales.md` (path tracing, denoise, grain/noise metrics), `video-vidcode.md`, `3d-assets-trellis.md`
  (mesh/GLB/texture quality), `image-quality.md` (NR-IQA, AIGC-IQA), `artifacts.md` (hands, text, anatomy),
  `aesthetics.md`, `dedupe-similarity.md`, `tagging-captioning.md` (SigLIP/CLIP, keywords), `faces.md`,
  `segmentation-granulometry.md` (incl. our Kaggle methods, no data), `efficient-inference.md` (GPU, Mojo, RDNA3),
  `evaluation.md` (gates, calibration on accepted sets, A/B with common random numbers, planted failures),
  `stock-platforms.md` (link to AssetsHQ marketplaces + mistakes, no copy), `build-list.md` (ranked next builds for
  mojo-cv with paper, expected number and gate). Add files if the cards show another domain.
- `references/papers.tsv`: all 207 with topic and the reference file that cites each.
- Every reference names our own receipts where they exist (mojo-cv stockcheck, mojo-faces, Gonzales grain numbers)
  next to the paper numbers, and says UNVERIFIED for any paper claim we have not reproduced.
- Link it into `~/Projects/AssetsHQ/.claude/skills/asset-vision`, mojo-cv, ComfyUI-v0.43.0, Gonzales, gpu-media/Blender
  and vidcode `.claude/skills/`; `skilldex`; a SKILLDEX line naming it the hub for visual assets.
- Done = a fresh agent loads only SKILL.md, picks the right reference for 5 sample tasks (one per domain), and the
  answers cite a paper id and a local receipt; record that check in the lane report.
