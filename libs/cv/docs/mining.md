# Mined from our other image projects (2026-11-16)

Methods and code only. Nothing from the Kaggle competitions' data moved here: no image, label, mask, cache or number derived from them.
Read: `filament-segmentation-2026` (docs `recipe.md`, `levers.md`, `rules.md`; `filseg/post.py`, `refine.py`, `metric.py`) and
`soil-grain-size-from-photos` (docs `plan.md`, `research.md`).

## Taken

| method | from | landed as | asset use |
|---|---|---|---|
| seeded threshold (hysteresis by region: keep a component of `src > lo` only if it reaches above `hi` and covers `min_area`) | `filseg/post.py instances` | `hysteresis` op, `src/mojocv/regions.mojo`, 6 oracle rows against cv2 components | drop isolated weak blobs from any mask; the building block of a region test |
| largest connected region instead of a pixel share | the same component bookkeeping | `clipRegion` op and the `blownVoid` flag: Adobe refused a blown void (one big region), a scattered 12 % clip is noise, not a void (planted: 10 % region against 0.001 %) | stock pre-check |
| the soil plan's gap table (what mojo-cv lacked for grain work) | `soil .../plan.md` "mojo-cv gaps" | `trayRim`, `trayCrop`, `granulometry*` already landed earlier; the open rows are below | tray crop is the one asset-side idea: crop to the inside of a frame or mat before measuring |

## Not taken, and why

- PQ metric, TTA, distillation, teacher caches, learned merging (`grouper.py`): training and evaluation of a segmenter; nothing in a
  stock pre-check consumes them.
- Speed levers (fp16, channels_last, fused kernels): GPU training of a network, not mojo-cv's CPU ops.

## Open (not built; the soil plan lists them as gaps, still absent in `docs/2d.md`)

| op | size | asset use |
|---|---|---|
| exact distance transform | S-M | thickness of a mask: how wide is a fog band or a stray object |
| region properties (area, centroid, Feret width, ellipse) beyond connected-component stats | S-M | size and shape of stray props and blank walls |
| watershed on the distance transform | M | count touching objects (a shelf of identical jars) |

The `cv-supervision` skill the research pane is building from the papers should decide which of these earn their cost.
