# Report: OpenAI vision papers into the asset-vision hub (2026-11-16)

Brief: `docs/lanes/2026-11-16-openai-vision-brief.md`. Boss pane wXY:p1. Lane pane wZ1:p1, resumed as wYV:p1 after a herdr crash.

## Result

All 14 papers are fetched, read, carded and indexed, and the hub routes to them. Every paper claim in the new reference is marked UNVERIFIED: no OpenAI model was run here.

| step | outcome | where |
|---|---|---|
| 1 ids | 8 of 8 brief ids matched their titles on the arXiv API; none fixed or dropped. 3 papers added (limit was 5): GLIDE 2112.10741, Point-E 2212.08751, Shap-E 2305.02463, because the 207 papers name them (GLIDE in 2607.03862, 2608.04935, 2607.24016; Point-E and Shap-E in Unifi3D 2509.02474) | `~/Brain/research/papers/openai-vision.txt` |
| 2 fetch | 11 arXiv PDFs by paperhub (`PAPERHUB_HTTP=tls`); iGPT from the PMLR PDF, DALL-E 3 captions from the openai.com PDF, Sora report as page text via crawl4ai | `~/Brain/research/papers/pdf/`, `paperhub/.work/study/openai-vision/text/` |
| 3 cards | 14 JSON cards, `study-check.sh`: `quotes found 139/139`, `OK all cards`. Added `cv_topic`, `mojo_cv_use`, `failure_modes` after the boss found them missing; key sets now equal the 207's (check printed `[]`) | `~/Brain/research/papers/openai-vision-cards/`, `mojo-cv-papers/cards/` |
| 4 store | 14 md cards, 14 full texts, 14 `index.tsv` rows in `mojo-cv-papers`, commit d5e4f52 | `~/Projects/mojo/mojo-cv-papers` |
| 5 neurons | full rebuild: 9553 neurons from 443 files (was 8814); `REFRESH_FORCE=1 refresh.sh` merged them (`grep -c mojo-cv-papers merged/net.paths` = 9553). `brain-ask --net text` returned a `mojo-cv-papers` hit as first store hit for each of the 14 papers when the query names the title | `~/.local/share/coios-brain/` |
| 6 hub | `references/openai-vision.md` (124 lines), route row in `SKILL.md` (now 78 lines), 14 `papers.tsv` rows, cross-links in `tagging-captioning`, `generation-comfyui`, `video-vidcode`, `3d-assets-trellis`; `build-list`: CLIP joins rank 1, sparse autoencoder is new rank 13. Brain commit afd06cddd | `~/Brain/Skills/own/asset-vision/` |
| 7 checks | `hub-check.sh asset-vision`: `PASS`; `route-test.sh` set `oai` (2 new prompts in `route-prompts.tsv`): `score 2/2`; `skilldex`: `PASS` | |

## What the papers give us (the ranked part)

Details and gates per paper are in `references/openai-vision.md`. Two changes to ranked builds: CLIP is the method reference of rank 1 (text-prompt tagging), and a TopK sparse autoencoder on SigLIP embeddings is rank 13, to name the concept behind a semantic refusal. Nothing else reorders the list: our open gap is semantic refusals (24 of 25 Adobe refusals), and these papers supply tools to look at it, not a result.

## Not done, or weaker than it sounds

- `route-test.sh` ran against `mojo-cv/.claude/skills` (13 skills), not the full global listing; 2 of 2 on a small catalogue is a weak routing proof.
- The proof queries name the paper title. A looser topic query ("CLIP zero-shot prompt template") returned other stores first (latentlora, papers), so a card is found by naming its paper, as the cv-research report found for the 207.
- The Sora text is the web page as crawled, with its page boilerplate (related articles, references) left in `text/openai_sora.md`; the iGPT and DALL-E 3 texts are cut at `References`.
- `study-check.sh` proves quotes are in the text, not that a card is deep; numbers were taken from lines read in the text, and one setting was corrected (iDDPM 3.77 bits per dim is ImageNet 64, not CIFAR-10). The DALL-E 3 card's claim that the 95% blend is the headline arm rests on the arm label, not on a result table I read.
- Extra papers: only 3 of 5 allowed, because the cards named no others.

## Mistakes of the lane

- Cards written to the documented schema without opening an existing card: `docs/rules.md` 25, `SINDEX/mojo-cv.md`.
- A herdr crash killed the neuron build mid-embedding (`gpu-wait: SIGTERM; job cancelled`) and the incremental rebuild then failed with `vecs short` / `FAIL drop`. `REPO_NET_FULL=1` rebuilt it (header of `repo-net.sh`). After any crash with a build running, run the full rebuild before trusting `net.paths`.
- Escapes used, all on literal searches of paper text or fetch output: `GRAPH_FIRST_ALLOW=1`, `BASH_BATCH_ALLOW=1`.
