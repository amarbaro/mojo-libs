# cvint report (2026-11-16): SigLIP labels beat the library's own categories, 0.80 against 0.40

On 40 library pictures I labelled by eye, SigLIP's top-1 category is right 32 times (top-3: 38), the category stored in the library 16 times. All 7593 library
pictures now carry stockcheck numbers, faces and SigLIP labels in `assets.db` (13233 assets, 7593 cv rows, 7593 label rows, `verify` problems 0). The label rows come
from the GPU runner (GpuNet, 41.6 ms per picture): its 7593 embeddings equal the CPU runner's on every row (cosine 1.000000000, max abs 4e-6), so swapping them in changed 0 labels. Mario approved applying them:
sidecar `category:` and `tags:` are SigLIP's in 7593 image sidecars, the old category is `library_category:` (5462 pictures differ, 2131 agree), the folder stays the import category.

Lane `cvint` (pane wYT:p1). Receipts are commits and files in each row; mistakes: `docs/rules.md` 10 to 19, `~/Brain/SINDEX/mojo-cv.md`.

## What the labels are worth

- 40 pictures (seeded draw, 7 allow an alternative label): SigLIP top-1 32 (0.80), top-3 38 (0.95); library category 16 (0.40). Sample with every tag: `docs/lanes/2026-11-16-siglip-sample40.md` (0baee81).
- All 7593 against the library category alone: top-1 0.281 (2131). That number mostly measures the library: game props sit under icons-ui (669 land on props), furniture and weapons overlap props (337, 243),
  and 37 % of predictions fall on `props`. One reworded `props` phrase gave 0.292 on the library but 29 of 40 on my labels, so the approved phrase stays.
- Tags (142, approved by Mario via the lead): 5849 pictures have at least one tag with p >= 0.002 in their top 5, 1744 have none. Probabilities are low and relative (laboratory 0.147 on a lab picture,
  tea 0.008 on a tea table); the floor is a policy that can change without rerunning the model.
- Predictions live in `label` and `<picture>.labels.json` only. Sidecar `category:` and `tags:` are untouched until Mario approves moving tags.

## Done

| piece | result | receipt |
|---|---|---|
| stock-review reads `<id>.stockcheck.json` | sidebar line `check lowres, face, 1 face(s)`; 6 core cases; a real-window gate reads the line back with tesseract (shown with a json, absent without) | stock-review 41ad876 |
| bulk-stock-tag reads the sidecars | `stockcheck` table, `stocktag stockcheck`, per-member flags in the cluster detail API; nothing is culled by it; 7 tests pass | bulk-stock-tag dab791c |
| stockcheck + faces over the library | 7593 png/jpg in about 1 h at load 25 to 48; `.stockcheck.json` beside each (git-ignored); 578 faces, 6182 under 4 MP, 4612 `duplicate` (24074 pairs), 872 `flatStrip`, 445 `blownVoid`, 282 `blur`, 206 `cast`; 2 not measurable | `.work/cvint/library.jsonl` |
| `assets.db` cv and label tables | live db rebuilt, `verify` problems 0; `assetdb` test: 25 value checks, 17 negative controls | AssetsHQ 21cc5fc (inside 34891fa), library 494a5c7 |
| SigLIP tokenizer in Mojo | ids equal transformers' SiglipTokenizer on 2000 of 2000 texts, planted change differs on 1998 | 338bb31 |
| text tower, CPU runner | cosine 1.0000000, max abs <= 6e-7 against onnxruntime on 12 texts | eadcab3 |
| image path | libvips squash against PIL: cosine 0.9993 to 0.9999 on 8 pictures | 26f0316 |
| ranking and label writer | `mcv-labels top` equals numpy; `scripts/siglip-labels.sh` writes the json | b2bfc72, bf4b9cf |
| library embeddings, CPU rows | 7593 pictures, 0 decode failures, 23325696 B | `.work/cvint/siglip-full.log` PASS |
| library embeddings, GPU rows | `mcv-labels gimage` on GpuNet under gpu-wait (priority 80, resumed after the herdr crash from row 2048); `tests/siglip_gpu.sh`: 7593 rows, cosine min 1.000000000, max abs 3.96e-06, planted shift differs on 7592 | `.work/cvint/siglip-gpu.f32`, `tests/siglip_gpu.sh` |
| labels applied to the sidecars | `scripts/siglip-apply.sh`: 7593 sidecars rewritten, a second run rewrites 0; old non-empty tags: 0 (nothing lost); `assetdb` gets a last column `library_category` and `verify` checks folder == library_category (28 value + 19 negative checks); live db rebuilt, `verify` problems 0, re-run by the lead with the same result | AssetsHQ 8ea4d4f, library eeeab8a, mojo-cv `scripts/siglip-apply.sh` |
| brainnet | the library's post-commit hook (installed earlier by the assets-index lane) ran `repo-net build` after eeeab8a: 13244 neurons (13233 sidecars + INDEX chunks), embedded on the GPU at 2241 rows/s, store 88 MB; the merge was deferred by `refresh.sh`'s 1800 s rate limit, so with Mario's OK I ran `REFRESH_FORCE=1 refresh.sh` (42 s bridge, rc 0): 13244 `text/library/` neurons in the merged network; `net-index --write` PASS; `brain-ask --net text "orange fox sitting in snow, category animals"` returns the fox render first: its sidecar says `category: animals`, `library_category: tech-devices` (the old path-word rule filed it there), `tags: [snow]` | `.work/cvint/refresh-force.log` |
| ledgers | 10 mistakes of this session: rules, SINDEX entries, skill rules (lanes 41-44, bench-gates 55-57, toolscript, mojo-cv skill), Brain note | Brain b2d1e1d0d, f56874632 |

## Speed

The CPU runner takes 0.85 to 1.4 s per picture solo (the 7.7 s in the assets-cv report was measured under load) and ran the library in about 1.6 h with other lanes active. On GpuNet (mojo-faces 9141c1c) one picture takes 41.6 ms, about 5 min for 7593.
Mario's rule 19: embeddings run on the GPU from now on.

## Open

- **232 face errors** (184 png, 48 jpg: grey, palette and 16-bit files the old loader refused): assetscv fixed the decode in 0d1e184; rerun those pictures once the queue clears and merge faces into their jsons.
- **TAGS Camera run** (6528 JPEGs, counts only into `~/Pictures/TAGS/.mojocv/`): not started; its face stage needs the GPU slot too.
- **mojo-faces `Gather` along axis 1** is missing in `faces.nn` (the text head takes the last token that way); `mcv-labels text` does that step in Mojo. Tell assetscv if `text_embeds` should run directly.
- Messages and commit b2bfc72 say 130 tags; `data/siglip/tags.tsv` has 142.
