# Plan: close the open mojo-supervision issues

## Context

Wave 1 merged at `3b281d1`. On Mojo 1.2.0 the full suite passes 1938 of 1941 rows. Six items are still open: the toolchain pin, mojo-cv on Mojo 1.3, the mojo-cv `_line2` bug, the mojo-cv resize tie rounding, segmentation datasets, keypoint mAP and text drawing (pure Mojo, decided). Goal: close all of them with the least new code, keep both toolchains building, and stay at C speed on the hot paths.

Rules for every item: reuse what exists first (mojo-lean steps 1 to 3), every change adds oracle rows to the existing harness (`tests/run.sh`, H1 row format), and the gate is `tests/build_all.sh && tests/run.sh` on Mojo 1.2.0 AND 1.3 nightly. Each item gets its own commit, with LOC before/after in the body.

## Items (cheapest first)

### 1. Toolchain pin (XS, about 5 LOC)
- Point mojo-supervision at Mojo 1.2.0 stable: replace the `.venv` link to `mojo-nightly` with the same pin mojo-cv uses (`pyproject.toml` + `uv.lock`, copied from `mojo-cv`).
- Add `tests/matrix.sh`: runs the gate once on 1.2.0 and once on `~/Projects/mojo/mojo-nightly/.venv/bin/mojo`, prints both versions. This uses the protocol's nightly-check shape (`~/Brain/protocols/mojo-library/README.md` §N).

### 2. mojo-cv builds on Mojo 1.3 (XS, 0 net LOC)
- `mojo-cv/src/mojocv/imgproc.mojo`: 21 `strided_store` calls become `unsafe_strided_store`. 1.2.0 already accepts it: it is the name the 1.2.0 deprecation warning points to, and lines 1051 to 1053 already use it.
- Gate: mojo-cv `scripts/ci.sh` on both toolchains.

### 3. mojo-cv `_line2` endpoint (XS, about 3 LOC in, about 30 LOC out)
- Fix `imgproc._line2` so it plots cv2 Line2's first endpoint (pt2 after the swap).
- Add the `cv_circle_outline` case to mojo-cv's `tools/fastpath_check.py` (bit exact vs cv2).
- Then delete S5's workaround `_fill_convex_fx` in `src/supervision/_cv/draw.mojo` and call mojo-cv directly. `pixels_cv` rows must stay 9/9.

### 4. mojo-cv resize tie rounding (S, about 20 LOC)
- Move cv2's fixed-point INTER_LINEAR rounding (S5's `src/supervision/_cv/ops.mojo resize_linear`) into mojo-cv's uint8 `resize` fast path, keeping its SIMD layout (uint16 math, `(v + 128) >> 8` style, mojo-lean uint8 section).
- Delete `ops.resize_linear` from supervision.
- Gate: `fastpath_check.py` bit exact on 1/3/4 channels and odd shapes; `tools/abbench.py` speed no worse than before (number in the commit).

### 5. Segmentation datasets (M, about 120 LOC)
Everything below already exists except two small pieces:
- Reuse `polygon_to_mask` (`detection/utils/polygons.mojo`), `mask_to_rle` / `rle_to_mask` (`detection/utils/converters.mojo`) and mojo-cv `find_contours` (`imgproc.mojo:2068`, Suzuki-Abe as cv2).
- New: `mask_to_polygons` as a thin wrapper over `find_contours` (about 25 LOC), and COCO compressed-RLE string encode/decode (about 40 LOC).
- Remove the raises in `dataset/coco.mojo` (lines 40, 164), `voc.mojo:54` and the polygon/mask rows in `yolo.mojo`. Wire them to the helpers.
- Oracle: extend `tools/gen_datasets.py` with segmentation fixtures (COCO polygon + RLE, YOLO polygon, VOC polygon), plus `mask_to_polygons` rows in `tools/gen_detection.py`.

### 6. Keypoint mAP (S, about 60 LOC)
- Make S2's COCO evaluator (`metrics/coco.mojo`) generic over its IoU function: one parameter, not a second evaluator (mojo-lean step 3).
- New: `_keypoint_oks_batch` (about 30 LOC) and `KeyPointMeanAveragePrecision` (about 20 LOC). Extend `key_points/core.mojo` only where the metric needs a field.
- Oracle: `tools/gen_metrics.py` adds keypoint mAP rows (Python `KeyPointMeanAveragePrecision`).

### 7. Text drawing, pure Mojo (XL, about 1,200 to 1,800 LOC)
Target: cv2 5.0 `putText` / `getTextSize` for FONT_HERSHEY_SIMPLEX (= built-in "sans", Rubik variable font). Scope is what that path uses, nothing more:
- **Font blob:** extract the gzipped Rubik from the cv2 `.so` (`builtin_font_sans.h`), check its OFL license, commit it, and credit it in NOTICE. Decode with mojo-gzip.
- **Font parsing** (`src/supervision/_cv/font/`, about 500 LOC): read `cmap` (formats 4 and 12), `head`, `hhea`, `hmtx`, `loca` and `glyf` (quadratic outlines, composite glyphs), plus `fvar`, `gvar` and `HVAR` (the wght axis: tuple deltas and IUP interpolation).
- **Shaping** (about 250 LOC): GPOS lookup type 2 (pair kerning). Check first whether Rubik's GSUB `liga`/`calt` changes Latin text; add GSUB type 1/4 only if the oracle rows show it does.
- **Rasterizer** (about 300 LOC): port hb-raster's coverage algorithm into an A8 mask. Source: `gh api` on harfbuzz `src/hb-raster*`, read before writing. Glyph cache keyed by (glyph, size, weight).
- **Layout and blend** (about 150 LOC): drawing_text.cpp conventions, i.e. ascender scaling (`scale = size*64*upem/ascent`), 26.6 pen advances, size `round(100*scale/3.7)`, weight 400/600 by thickness, then alpha blend.
- **Out of scope:** RTL, BiDi, script runs, fallback fonts (only "sans" is always built in).
- **Then:** wire `putText` and `getTextSize` into `_cv`, and add label annotators back into S5's annotators.
- **Oracle:** the 3 descoped rows, plus `tools/gen_pixels.py` text rows (ASCII strings, scales 0.3 to 2.0, thickness 1 and 2). Bar: max abs diff and differing-pixel % stated per row, starting at 0. If hb-raster parity is not exact, report the measured diff rather than loosen the bar.
- **Split into sub-commits:** parser, gvar, GPOS, rasterizer, layout. Each gets its own unit rows against fontTools in the oracle venv.

## Dispatch

Two Sonnet lanes (`sonnet[1m]`, effort high), each in its own worktree via `lanes.sh`, with the boss pinning item 1 on main before either starts:
- **Lane F (fixes): items 2 to 6, in that order.** Items 2 to 4 are commits in mojo-cv (its own worktree; the boss merges into mojo-cv main), and items 5 and 6 are in mojo-supervision. The lane writes its own oracle rows first, in the wave-1 contracts.
- **Lane T (text): item 7**, as the staged sub-commits above, with its own oracle rows first. The boss reviews the rasterizer sub-commit before layout starts.

No shared files: F touches dataset, metrics, `_cv/draw.mojo` and `_cv/ops.mojo`, while T touches only `_cv/font/`, plus the `putText` wiring and label annotators at the end, after F's `_cv` edits are merged. The boss re-runs every gate before merging.

## Verification

- Gate per item: `tests/build_all.sh && tests/run.sh` on 1.2.0 and on 1.3 nightly (`tests/matrix.sh`); mojo-cv `scripts/ci.sh` + `fastpath_check.py` for items 2 to 4.
- End state: 0 failing rows (1941 plus the new rows), both toolchains green, `mojo-loc` totals before/after in each commit.
- Speed: `abbench.py` for resize; `mojo-bench` for putText against cv2 on a 640x480 label scene.
