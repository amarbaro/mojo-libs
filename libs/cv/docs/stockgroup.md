# stockgroup: the CV half of a stock database

`scripts/mcv-stockgroup DIR [k=v...]` groups 194 phone photos into 90 items in about 70 s and writes `DIR/cv.jsonl` (one row
per photo) and `DIR/cv-groups.json` (one entry per item). DIR holds the photos in `DIR/work/` (1024 px copies) with the
originals in `DIR/raw/` for the EXIF time, or the photos directly. Stages: CPU decode (libvips, ImageMagick for ICC files; never
VAAPI JPEG), `mojo-cv stockPhoto` (CPU, parallel), EXIF time (exiftool), SigLIP embeddings (`scripts/siglip-embed.sh`, GPU under
`gpu-wait`, 25 s of the 70), `mojo-cv stockGroup`, then a jq merge.

## Row

```
{file, t, sharp, box, group, view, view_rank, dup_of, empty, boxShare, clip:{lo,hi}, gap, cos, p_same, w, h, tenengrad, dhash}
```

| field | meaning |
|---|---|
| `t` | EXIF DateTimeOriginal + SubSec (seconds), from `raw/` first, then the photo, then the `IMG_YYYYMMDD_HHMMSS` name; none of the three: FAIL |
| `sharp` | variance of the 4-neighbour Laplacian at the stockcheck analysis scale (long edge about 1536; 1024 px photos are not shrunk). Same op as `mcv-stockcheck` |
| `clip` | share of pixels <= 3 and >= 252 |
| `box` | `[x0,y0,x1,y1]` px of the photo, x1 and y1 exclusive; `null` = no subject. `boxShare` = box area over photo area |
| `empty` | no subject and a clean cloth (background MAD <= 10): a frame to skip |
| `group` | item number in time order, `null` for an empty frame |
| `view` | distinct view inside the item (0, 1, ...) |
| `view_rank` | 0 = sharpest photo of its view; `dup_of` names that photo for the others |
| `gap`, `cos`, `p_same` | seconds and embedding cosine to the previous non-empty photo, and the item-boundary score |

`cv-groups.json`: per item `{group, n, t0, t1, files, views, best}` (`best` = the rank-0 photo of every view). It is not called
`groups.json`: the driver keeps its own item labels there.

## The subject box misses the 0.7 bar on hands

Nine photos with hands, boxes labelled by eye off a grid (`tests/stock_hand_boxes.tsv`, about 5 % of the frame of slack): mean IoU
0.55, 3 of 9 at IoU >= 0.7. The brief asked for 0.7 on each: NOT met. The first version (union of every large region, tape rule
"half the frame wide") scored mean 0.38, 2 of 9. What still fails: a watch lying between fingers that is itself skin-coloured (the
box shrinks to the strap), and a hand blob under 1.5 % beside the watch. `tests/stock_group.sh` records 0.50 as the floor.

`stockPhoto` (`src/mojocv/stockphoto.mojo`), on the picture shrunk to a long edge near 256: the tape (hue 20-36, S >= 140,
V >= 130, a yellow region at least 15 % of the long edge and 4 times longer than wide) and hands (YCrCb skin range Y >= 70,
Cr 133-173, Cb 77-127, opened by 19 px, kept when the blob touches the frame edge and covers >= 1.5 % of the picture, or covers
>= 8 %) are masked out and dilated by 6 px. The cloth is the median grey of the rest and the subject is what departs from it by
more than max(25, 4 robust sigma). The box is the foreground region with the most area near the middle of the frame, plus every
region of at least 8 % of its area within 6 % of the long edge of the box so far.

## Items, views and near-duplicates

`stockGroup` (`src/mojocv/stockgroup.mojo`) scores consecutive photos (empty frames skipped) with a logistic on
z(log10(gap s + 0.5)) and z(SigLIP cosine); p > 0.5 is the same item. Fitted on the 193 pairs of the 194 photos of 2026-11-22
against the driver's 89 items (Sonnet vision and OCR labels in `groups.json`; indices are time order, which a name-order
reading disproves: F1 0.35): pair accuracy 0.912, and a gap <= 25 s alone also gives 0.912. An unsupervised two-component EM
gave 0.881 and was dropped. The whole grouping against the driver's items: pair precision 0.77, recall 0.84, F1 0.80, with 90
items against 89. The driver's labels are a measured agreement, not ground truth.

Front and back of a watch look alike (same-item consecutive cosine: median 0.87, 90th percentile 0.92), so two photos are one view
only when cosine >= 0.95 or dHash <= 6 bits. All constants are `k=v` arguments (`gmu gsd cmu csd wg wc bias burst maxgap vcos
vham`).

## Checks

`tests/stock_group.sh`: a planted disc on cloth with tape (IoU 0.91), the same with a hand at the edge (0.91), an empty cloth (no
box, empty), a planted shoot of 4 items with a repeated shot and an empty frame, and the nine labelled photos when
`~/Projects/ebay.de/.work/stock-20261122/work` exists.
