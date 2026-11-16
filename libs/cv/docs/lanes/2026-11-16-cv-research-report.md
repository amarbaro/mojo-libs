# cv-research report (2026-11-16)

Brief: `2026-11-16-cv-research-brief.md`, with the scope change that made step 5 the hub skill `asset-vision`.

## What was delivered

| step | result | check that passed |
|---|---|---|
| 2 select | 208 arXiv papers from 1152 candidates (81 topic queries, 2024-06 onward), `docs/research/cv-papers.tsv` | ids joined to triage by key; one unscored id and one empty-id row found and dropped (rule 21) |
| 2 fetch | 207 of 208 PDFs with paperhub (`arxiv:2603.15253` has no PDF) | `done` file holds 207 lines of 208 |
| 3 cards | 207 JSON cards by Haiku helpers (three panes), `paperhub/.work/study/cv-stock-2026/cards/` | `study-check.sh`: quotes found 1586 of 1586, `OK all cards`; `cardnums.py`: 412 card numbers have all digits in the paper text |
| 3 sample | 20 cards drawn at random and read against their text | 12 had checkable numbers: 9 matched their sentence, 3 matched only small digits (not conclusive); 8 cards carry no number. Every number cited in the skill (28 claims) was grepped in its text; the two claims that needed context (pHash AUROC about 0.50 in 2505.11034, ROC-AUC 0.550 in 2609.32734) were read in context and hold |
| 4 neurons | repo `~/Projects/mojo/mojo-cv-papers` (207 cards as md and json, full text as md), commit 16741a7, post-commit hook installed | see "Neurons" below |
| 5 skill | `~/Brain/Skills/own/asset-vision/`: SKILL.md hub, `rules.md` (71 ledger rules cited `[ledger:file:line]`), 16 references, `references/papers.tsv` (207 rows with topic and reference) | `hub-check.sh asset-vision`: PASS; route test and done check below |
| 6 own projects | methods (no Kaggle data) from the filament and soil competitions, mojo-faces, stock-review in `segmentation-granulometry.md`, `evaluation.md`, `efficient-inference.md`, `faces.md` | text only; no image, label or derived data copied |
| 7 notes | Brain note `~/Brain/mojo-cv/2026-11-16-cv-research.md`, ledger entries and rules 19 to 24 | commits recorded in the note |

## Route test and done check (asset-vision)

- `route-test.sh` against `~/Projects/AssetsHQ/.claude/skills` (37 skills plus the hub), 14 prompts for this hub (10 dev, 4 held): 12 of 14 correct in each of two runs (a member skill counts as correct). Run 1 misses: "compare two filament segmentation recipes" went to `bench-gates`, "pick the nicest of twenty renders" to `image-gen-edit`. After one wording change in the description (adding picking the best of N renders and A/B of vision recipes) run 2 missed the filament prompt again and "measure grain size of sand" went to `research`. The held set was used twice, so treat 12 of 14 as the number, not as a fresh held-out result. Whole-catalogue scores (34 to 36 of 70) count other hubs' prompts that this catalogue cannot answer.
- Done check: a fresh Haiku with only SKILL.md picked the right reference for 5 tasks (ComfyUI OOM, Gonzales edges, LTX motion claim, TRELLIS shattered GLB, garbled text) and each answer named an arXiv id and a local receipt from the file. It found one real gap: the ComfyUI reference did not carry the `--reserve-vram 2.5` fix, which lived only in `rules.md`; the reference now states it. Some answers named an arXiv id that is unrelated to the task (HyperAlign for a VRAM question): the id sits in a table of papers, so a task needs the reference's own receipts first.

## What failed or is open

- Haiku at effort low drafted shallow first cards (28 numbers in 43 cards); later slices were deeper. The checker proves quotes, not depth (rule 24). Cards are hints; the build list names only claims that were grepped.
- A boss broadcast pulled both helpers off the card job (rule 23). A third helper pane was added to finish slice 3 in time; the brief said one.
- Every paper claim in the skill is UNVERIFIED for our files. No paper method was reproduced; the ranked build list gives each build a gate that must pass on our own pictures first.
- `granulo` has 2 papers: arXiv 2024 to 2026 has little new on classical granulometry.
- GPU was not used by this lane except the network embedding (see Neurons).
- Mistakes of the lane: `SINDEX/mojo-cv.md` and `docs/rules.md` 19 to 24 (paperhub shim, one-batch get-list, id join, wait marker, broadcast, shallow cards); lanes rules 45 and 46; paper-study section "Large lists".

## Neurons

`repo-net build` of `~/Projects/mojo/mojo-cv-papers` passed: 415 files, 8814 neurons (486 card neurons); the post-commit hook is installed (`PASS hook`). The merge into
the Brain network was deferred by about 22 minutes (`trailing run in 1311 s`); a query before the merge returned no card of this store. After the merge
(`grep -c '^text/mojo-cv-papers/' merged/net.paths` = 8814):

`brain-ask --net text "CleanPatrick benchmark for image data cleaning near-duplicates Fitzpatrick17k mojo-cv use"` returned
`mojo-cv-papers/cards__arxiv_2505.11034v2.md/0` (score 7.11) as the first hit, then four text chunks of the same paper.
A looser query about perceptual-hash near-duplicate AUROC returned a text chunk of a different paper from the store (2608.03101), not the CleanPatrick card, so
a card is found by naming its paper or its topic words, not by quoting a number.
