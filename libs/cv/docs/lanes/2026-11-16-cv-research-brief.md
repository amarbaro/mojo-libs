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
