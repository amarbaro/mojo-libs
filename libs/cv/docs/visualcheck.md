# visualcheck: "just a shape" detector for 3D listings and pictures

`stockcheck` passes a sharp, well exposed grey box. These signals look at what the box lacks: colour on the object, detail inside
the silhouette, an outline that is more than a few straight edges, and large areas of one flat shade.

`scripts/mcv-visualcheck [-j N] [-c CHUNK] OUT.jsonl LIST.tsv [k=v...]` decodes each picture (`scripts/decode-stock.sh`), runs
`mojo-cv visualCheck` (`src/mojocv/visualcheck.mojo`, CPU, parallel) and writes one JSON line per picture. `LIST.tsv` rows are
`path<TAB>kind`, kind `view | preview | image | texture | frame`. A picture that cannot be decoded gets a line with `"error"` and no
numbers; the wrapper fails when result lines differ from the list. Test: `tests/visual_check.sh` (16 checks on planted pictures: flat
box, disc, 5-point star, colour-noise object, blank, uniform, plasma photo, missing file, `.ppm` equals PNG).

## Signals

The object mask is what departs from the backdrop: the backdrop colour is the per-channel median of the 2 px border ring, and a
picture whose border is not uniform (more than 25 % of border pixels differ by over 14) is a photo and counts as all object. Everything
is measured on the picture shrunk by an integer area mean to a long edge near 384 px. Texture is measured inside the mask eroded by
2 px, so the silhouette edge never counts as detail, on a gamma-lifted luma (x^0.45) so a dark render is judged like a bright one.

| key | meaning |
|---|---|
| `fill`, `bgbad`, `empty`, `comps` | object share of the picture; border pixels off the backdrop colour; no object found; outer contours of 20 px or more |
| `chroma`, `chp90`, `chstd`, `sat` | max-min channel spread on the object (mean, 90th percentile, std), mean saturation |
| `palette`, `huen` | 3-bit-per-channel colour buckets holding at least 0.5 % of the object; of 12 hue bins, those holding at least 3 % of the coloured pixels |
| `lstd`, `ent`, `lf` | luma std, 64-bin luma entropy, std of 8x8 block means (blotches, large patterns) |
| `hf`, `hfshare`, `lapq`, `edge`, `flat` | mean and share of the inner pixels by Laplacian (>= 6, >= 24), share with central-difference gradient >= 12, share whose 5-point luma range is <= 2 (a flat shade or a smooth ramp) |
| `complex`, `solid`, `corners` | longest outer contour: length^2 / (4 pi area) (disc 1, square 1.27), area / convex hull area, Douglas-Peucker vertices at 2 % of its length. Meaningless for a photo (the contour is the frame) |
| `prim` | flat-shaded primitive score 0..1: geometric mean of flat share, few colour buckets, no fine detail, plain outline (uncalibrated, kept for reading) |
| `blank`, `seam`, `stretch`, `plain` | "textured only in part" (`src/mojocv/texdefect.mojo`, measured on the mask eroded by 4 px, so the silhouette never counts). `blank`: share of the object that is light (above 0.3 of its own 95th percentile in linear luma), low in saturation (under 0.12) and flat once shading is divided out (5x5 std over mean of linear luma under 0.05). `seam`: edge pixels with texture (5x5 std of lifted luma at least 4) 6 px to one side and blank (at most 1.5) to the other, kept when they lie on a straight Hough line of at least 24 px (24 angle bins, 3 px rho), as line pixels per sqrt(object area). `stretch`: energy-weighted length of the mean coherence vector of the structure tensor of the shading-free texture (9x9 window), away from strong edges; 0 for isotropic texture, near 1 when all texture runs one way. `plain`: `blank` without the colour and light conditions, the share that is flat in any colour (an untextured barrel in its material colour). Test: `tests/texdefect.sh` (planted white box, shaded white box, brown flat box, textured box, half-textured box, streaks, isotropic noise). They add to the keys; the verdict above does not use them |
| `score`, `verdict`, `reason` | see below |

## Verdict

- `preview` (the 200 px store listing picture, grey backdrop) and `view` (the 512 px ortho sheet of asset-check, black backdrop):
  score = 100 * P(good) of a logistic model on standardised `sat`, `edge`, `flat`, with monotone weights (colour and detail never
  lower the score; an unconstrained fit gave detail a negative weight and scored a plasma texture 0). `bad` under 40 (preview) or 45
  (view), `ok` from 60, else `weak`; `badcut=` and `okcut=` override. Fit by `tools/visual-fit.sh` in AssetsHQ.
- `image`, `texture`, `frame` have no labels: fixed rules. `bad` = no object on the backdrop, luma std under 3 (texture 1, frame 4) or
  flat share over 0.985; `weak` = luma std under 8 (texture 3, frame 12), flat share over 0.95, or a graphic of 3 colour buckets or fewer with
  almost no detail.

## Calibration (AssetsHQ, 2026-11-28)

Labels: bad = low-poly (under 2000 triangles) members of the store's 3D packs (1115); good = the 3 food stalls and the 3D assets with
over 20000 triangles and a texture of 1024 px or more (466). Fit on the half whose sha256 starts with 0-7, scored on the other half.

| kind | test n | bad precision | bad recall | not-ok recall | good kept ok |
|---|---|---|---|---|---|
| preview | 746 | 0.956 | 0.877 | 0.936 | 0.825 |
| view | 829 | 0.823 | 0.730 | 0.900 | 0.439 |

The same low-poly models look textured and fine on the asset-check view sheets (black backdrop, lit, baked texture) and grey and
untextured in the store previews: the previews are where the "plain grey box" shows, and the view sheets cannot be trusted alone.
The labels are geometry and texture size, not looks: a good-labelled asset that renders flat is a true flag, a bad-labelled one that
looks rich a false one, so precision and recall are lower bounds on agreement with a person's eye, not accuracy.
