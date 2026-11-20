# Plan: mojo-supervision, Roboflow supervision ported to Mojo

Source: `~/Downloads/supervision-develop.zip` (MIT, 96 .py files, 1.8 MB), unpacked at `.work/supervision-develop`.
Direct port with attribution in `NOTICE` (MIT allows it). Image ops come from mojo-cv
(`~/Projects/mojo/mojo-cv/src`, `-I`), never reimplemented; supervision's `_cv2` wrappers map onto mojo-cv calls.
Missing mojo-cv op -> QUESTION line in exchange/team.md, boss routes it to the mojo-cv lanes.

## Scope: everything, two lanes

| Lane | Modules (src/supervision/...) | Order |
|---|---|---|
| A data + math | detection (Detections, NMS/NMM, utils, converters, tools: zones, line counter, inference slicer, smoother, csv/json sinks), metrics (mAP, precision, recall, F1, confusion matrix), dataset (COCO/YOLO/VOC load+save, split, merge), classification, validators, config | S0 Detections first, then detection, metrics, dataset |
| B pixels | draw, geometry, annotators (all), key_points (+ annotators, skeletons), depth, utils (image, video, notebook-free parts), assets (fixture fetch only) | geometry + draw first (no dependency), then annotators once S0 lands |

## Contract
Lane A commits `src/supervision/detection/core.mojo` (S0: struct Detections: xyxy, mask, confidence, class_id,
tracker_id, data; filtering, merge, area) first and logs `S0 READY <hash>` in exchange/team.md. Lane B merges that
commit, never edits it; changes go through a team.md request that lane A applies.

## Gates (oracle = Python supervision installed from the zip in .work/oracle-venv)
- Numeric ops: same inputs through Python supervision, equal within 1e-6 (rows in tests/supervision/cases/*.txt).
- Dataset: load -> save round trip byte-equal to Python's output on fixture datasets.
- Annotators/draw: pixel diff vs Python supervision (on cv2) per row, max abs diff and differing-pixel % recorded;
  bar per row stated in the row, never loosened to pass.
- tests/supervision/run.sh runs all rows; every item: own rows + full suite -> .work/<item>-gate.txt.

## Rules
Mojo in src/, Python only in tools/supervision/ (oracle). One commit per green item, conventional subject + why body, no
attribution trailer. 3 repair attempts then .work/<item>-failure.md. No push/merge/tag: boss merges.
Estimate: ~6-9k Mojo LOC (XL+).
