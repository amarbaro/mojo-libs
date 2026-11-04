# Team plan: mojo-supervision, 5 Sonnet + 5 Haiku

This plan splits `docs/plan.md` into 10 lane items. Scope, contract, gates and rules in `docs/plan.md` stay authoritative.

- Main repo: `/home/mario/Projects/mojo/mojo-supervision`.
- `.work/` in each worktree is a symlink to the main repo `.work/`. Python source: `.work/supervision-develop/src/supervision/`. Oracle venv: `.work/oracle-venv` (H1 builds it, everyone uses it).
- Shared log: `/home/mario/Projects/mojo/mojo-supervision/exchange/team.md`. Append only, one line per event: `<item> READY|QUESTION|BLOCKED <sha or text>`.

## Dependency

```
H1 harness ─┬─ H2 rows detection ── S1 S0+detection ── S1 READY ─┬─ S2 metrics   (H3 rows)
            ├─ H3 rows metrics                                    ├─ S3 dataset   (H4 fixtures)
            ├─ H4 dataset fixtures                                ├─ S4 tools
            └─ H5 pixel refs                                      └─ S5 pixels    (H5 refs)
```

Rows go in `tests/cases/`, fixtures in `tests/fixtures/`. A Sonnet lane merges the H branch it needs (`git merge lane-H<n>`) after that lane logs READY. It never edits H files; it asks in team.md. Before S1 READY, S2 to S5 read the Python source and code against the S0 struct spec in plan.md. At S1 READY they merge `lane-S1`.

## Items

### H1 (haiku): oracle venv + harness
Build `.work/oracle-venv` with uv, installing Python supervision from the unpacked source, offline. `tests/run.sh` runs every row file in `tests/cases/*.txt` against its Mojo binary, prints `PASS/FAIL <file>:<line>`, and exits non-zero on any FAIL. Document the row format in `tests/README.md`. `tools/oracle.py` holds the shared generator helpers. Log READY first: the other H lanes wait for it.

### H2 (haiku): oracle rows, detection core + utils
`tools/gen_detection.py` writes `tests/cases/detection_*.txt`: Detections filter/merge/area, box_iou, mask_iou, NMS, NMM, converters (xywh, xyxy, cxcywh, polygon to mask and back). At least 300 rows; state the seeds.

### H3 (haiku): oracle rows, metrics
`tools/gen_metrics.py` writes `tests/cases/metrics_*.txt`: mAP (50 and 50:95), precision, recall, F1, confusion matrix. At least 150 rows.

### H4 (haiku): dataset fixtures
`tests/fixtures/datasets/`: small COCO, YOLO and VOC sets (at most 20 tiny PNG images each), plus Python outputs for load then save, split and merge, byte-exact. Generator: `tools/gen_datasets.py`.

### H5 (haiku): pixel references
`tools/gen_pixels.py` writes `tests/fixtures/pixels/`: one input image plus the Python supervision output per annotator and draw primitive (box, label, mask, polygon, circle, dot, halo, blur, pixelate, trace, keypoints), each with a row that states its bar.

### S1 (sonnet): S0 Detections + detection
Write `src/supervision/detection/core.mojo` (S0) first, commit it, and log `S1 READY <sha>` in team.md. Then: detection utils, NMS/NMM, converters, classification, validators, config. Gate: H2 rows.

### S2 (sonnet): metrics
`src/supervision/metrics/`. Gate: H3 rows.

### S3 (sonnet): dataset
`src/supervision/dataset/`: COCO, YOLO and VOC load and save, split, merge. Gate: H4 round trips, byte-equal.

### S4 (sonnet): detection tools
Zones, line counter, inference slicer, smoother, csv and json sinks. Gate: S4 writes its own generator `tools/gen_tools.py` and its rows.

### S5 (sonnet): pixels
Geometry, draw, annotators, key_points, depth, utils (image and video). Image ops come from mojo-cv (`-I /home/mario/Projects/mojo/mojo-cv/src`). A missing op goes to team.md as QUESTION. Gate: H5 pixel refs.

## Lane rules (all)
- No subagents, no forks. Write only in your worktree, except appending to team.md and your report.
- Python only in `tools/`, Mojo only in `src/`. Never edit another lane's files.
- Work through without waiting for prompts. End with READY, PARTIAL or BLOCKED, then DONE.
