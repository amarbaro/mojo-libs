# cvstock lane report (2026-11-23)

`scripts/mcv-stockgroup DIR` groups the 194 ebay.de photos into 90 items in about 52 s and writes `cv.jsonl` and `cv-groups.json`; the
GPU twins of five per-image ops are byte-identical to the CPU ops and win up to 15x on a 50 MP picture, but a GPU stage inside the batch
lost (2.2x slower) and was deleted. Three items stay open: the box misses its 0.7 bar, the GPU stall budget is blocked, the absolute
cm scale has no ground truth.

## Delivered

| item | result | receipt |
|---|---|---|
| `mcv-stockgroup DIR` | 194 photos, 52 s, 90 items, 19 near-duplicates, 2 empty frames; EXIF time, SigLIP on the GPU (`gpu-wait`), CPU stage as one cpu-room job | `docs/stockgroup.md`, commits 84e4abbb 9af42fff |
| items against the driver's labels | pair precision 0.77, recall 0.84, F1 0.80 (90 against 89 items); gap alone 0.912 accuracy, logistic 0.912, EM 0.881 (dropped) | `docs/stockgroup.md` |
| subject box on 9 hand-labelled hand photos | mean IoU 0.56, 4 of 9 at 0.7; first version 0.38, 2 of 9. **0.7 target not met.** `hand` share exposed (31 photos above 0.02) | `tests/stock_hand_boxes.tsv`, `tests/stock_group.sh` |
| tape scale `px_per_cm`, `box_cm` | planted tape 59.9997 for 60; 174 of 194 photos; box short side median 3.27 cm (p10 2.0, p90 4.5), the driver read it as plausible (33 mm median). **Absolute value UNVERIFIED**: no known watch case was measured (candidate IMG_20261123_021007 left to Mario) | `docs/stockgroup.md` |
| GPU twins (`gpu=1`): grey, area shrink, sharpness, Sobel 3x3, crop | 25 of 25 oracle rows (cv2 5.0 / numpy) pass, 10 exact; crop = numpy slice; hidden GPU writes the CPU file; 2D rows 442 of 442, 3D 161 of 161 | 9e1a7399, `tests/run_gpu.sh`, `docs/gpu.md` |
| speed, 50 MP grey, CPU / GPU ms (copies included) | sharpness 187.1 / 12.1; boxDown f=4 14.8 / 2.04; crop 68.3 / 7.06; **losses** kept on the CPU: grey 3.91 / 7.33, Sobel 4.66 / 6.01 | `tests/bench_gpu.sh` |
| `mat::load` exact-size read | peak RSS of 48 loads of 50 MP: 4.05 and 4.54 GB before, 3.08 and 3.19 GB after; wall 8.96 and 7.77 s before, 4.25 and 5.56 s after; same output bytes | heaptide peak site `FileHandle::read_bytes <- mat::load` |
| JPEG decode | CPU only (vips, ImageMagick for ICC files): 3.0 s per 50 MP photo; never VAAPI JPEG | `docs/gpu.md` |

## Not done, and why

- **Box on hands at IoU 0.7**: 4 of 9. Fails: a skin-coloured watch between fingers, a thumb in shadow, a hanging watch whose dial and strap are
  far apart. Looser skin growth swallowed the cloth. The driver should treat a box with `hand` > 0.02 as unreliable.
- **`wavewait budget`, stall tables**: the ATT capture was refused twice by the session's permission classifier; the command for a manual run is in
  `docs/gpu.md`. No win is locked by a budget.
- **heaptide on the GPU side**: a GPU process dies under its `LD_PRELOAD` (rule 35); RSS and wall are the numbers, VRAM peak UNVERIFIED (the sampler read 0).
- **`stockPhoto gpu=1`**: built, measured 20.8 s against 9.5 s, deleted (rule 34).
- **ci.sh**: 2D 442 of 442 and 3D 161 of 161 pass on the final tree; the supervision stage fails on 15 stale binaries in the git-ignored `build/`
  (built 11-20 with another toolchain, `libKGENCompilerRTShared.so` missing; `build_all.sh` skips existing binaries). Deleting them was refused by the
  classifier, so the supervision rows are UNVERIFIED on this tree; removing `build/` and rerunning `tests/supervision/build_all.sh` fixes it.
- `uv.lock` changed by `uv sync` (the venv for the oracle) and was not committed.

## Mistakes (docs/rules.md 28 to 37, `~/Brain/SINDEX/mojo-cv.md`)

A deliverable name the driver already owned (`groups.json`, restored from a copy, now `cv-groups.json`); colour masks without a shape rule; a grey twin from
the wrong weights; a GPU stage measured after it was built; a profiler plan that was not probed on 12 rows; waits on a busy GPU queue (rule 37).
