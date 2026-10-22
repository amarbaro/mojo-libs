# Plan: finish mojo-cv (after lanes L2D and L3D, 2026-10-22)

State: L2D and L3D merged (e991adb), 195 cv2 rows + 161 3D rows green, clean-room PASS. Open: real-world checks,
speed (10 of 39 1080p ops beat cv2), three algorithm deviations, six missing ops, release. Estimate ~1700-2200 LOC.

Standing rules (every item):
- Clean room: never open `~/Projects/AMD/.work/solidcv-zip` or `solidcv-vault`, nor any solidcv copy. Sources: OpenCV
  5.0 docs and the papers in `docs/provenance/2d.md`.
- Mojo only in `src/`; Python only in `tools/` as the oracle (`~/iTools/video/camera-motion/v/bin/python`).
- Gate after every item: `tests/run.sh` (all cv2 rows) and `tests/run3d.sh` (161 rows) both green, output to
  `.work/<item>-gate.txt`. A row may never be weakened to pass. Commit each green item on branch `finish`.
- Speed numbers come from `tests/run.sh --bench-all --md docs/bench.md` before and after; commit body carries
  `hot path: OP · before A ms · after B ms · cv2 C ms` (memory-optimization) and `loc: before/after` (mojo-lean).
- Three repair attempts per item, then `.work/<item>-failure.md` and move to the next item.
- Report: `exchange/finish-report.md` (per item: done/failed, numbers, commits).

## F1 Real-world checks (~150 LOC, do first)
- `tools/fetch_fixtures.sh`: `kaggle datasets download danielwe14/stereocamera-chessboard-pictures` and
  `crsuthikshnkumar/aruco-marker-data-set` into `tests/real/` (gitignored), convert a sample to `.mcv`.
- Case rows on real inputs: findChessboardCorners + solvePnP on 5 chessboard photos (vs cv2), ArUco detection on 5
  marker photos (vs cv2), ORB + BFMatcher + calcOpticalFlowPyrLK tracking across 100 frames of
  `~/Videos/obs.space/2026-01-25 15-05-00.mkv` (decoded with ffmpeg to gray .mcv): tracked-point error vs cv2's
  tracks, median < 1 px.

## F2 Speed: the 26 slow 1080p ops (~600-1100 LOC, mostly replacing loops)
Cause (docs/bench.md): scalar per-pixel loops through bounds-checked `Mat.at`; cv2 is hand-vectorised. One pattern per
op family, applied and measured family by family, slowest first:
1. Pointwise/row ops: cvtColor, threshold, flip, transpose (blocked), convert, integral: raw row pointers,
   `vectorize` over the row, `core.par` (8 workers) over rows.
2. Separable filters: GaussianBlur, Sobel, erode/dilate (van Herk/Gil-Werman for rect), pyrDown, blobFromImage:
   row pass + column pass on SIMD lanes, one scratch row per worker.
3. Samplers: resize (all modes), warpAffine, remap: precomputed per-column coefficients, SIMD gather-free inner loop.
4. Canny, goodFeaturesToTrack: vectorised gradient and NMS; hysteresis stays scalar.
5. ORB: FAST on SIMD rows; HOG: integral-histogram so each block is summed once.
GPU only for an op where a measured GPU run beats the best CPU run (gpu-wait run --timeout S; blockdiff lesson:
memory-bound ops stay on CPU). Target per op: <= cv2; report every op's before/after either way.

## F3 Algorithm deviations (~550 LOC)
- solvePnP: EPnP (Lepetit 2009) + Gauss-Newton refine replacing the homography/DLT path; solvePnPRansac uses it.
- findEssentialMat: Nister 5-point inside RANSAC replacing 8-point MSAC.
- stereoRectify: alpha in [-1, 1] and vertical baselines.
Each: existing rows stay green and new rows compare to cv2 on the same inputs (tighter tolerances where cv2 matches).

## F4 Missing ops (~350 LOC)
cvtColor Lab and Luv, resize INTER_AREA, findContours hierarchy (RETR_TREE/CCOMP), thick lines, Harris option in
goodFeaturesToTrack, THRESH_TRIANGLE. Two case rows each (real image + edge case) vs cv2.

## F5 Release (~20 LOC)
README status table, `docs/bench.md` regenerated, release note via `~/iTools/bin/release-note`, tag v0.1.0.
