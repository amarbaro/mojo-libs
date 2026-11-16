# stockcheck: pre-checks for stock-site rejections

Pixel statistics catch the technical rejections (under 4 MP, blur, static, JPEG blocks, banding, blown exposure, cast,
twins) and miss the semantic ones, which are 24 of Adobe's 25 refusals in our labelled set. Measured on 128 real files
(46 Adobe-accepted, 7 refused for quality, 18 for similar content): no number separates the quality refusals from the
accepted pictures except db067's white-out, and that one only at a cost of false alarms (see the last section).

`scripts/mcv-stockcheck [-j N] [-c CHUNK] [--sidecar] OUT.jsonl IMAGE|@LIST... [k=v...]` decodes images (ImageMagick,
EXIF orientation and ICC applied, `scripts/img2mcv.sh`), measures them with the ops below in one parallel Mojo run and
writes one JSON line per image. `--sidecar` also writes `IMAGE.stockcheck.json` beside each image, for the pass/deny app
(`~/Projects/mojo/stock-review`) and bulk tagging (`~/Projects/tools/bulk-stock-tag`). An image that cannot be decoded or
measured gets a line with `"error"` and no numbers; the wrapper fails if result lines differ from the image count.

## Output line

```
{"file", "w", "h", "scale", "mp", "bytes",
 "sharp":{"lapvar","tenengrad","softTiles"}, "noise":{"sigma","nbr"}, "blocks",
 "clip":{"lo","hi","p01","p99"}, "cast":{"rg","by"}, "band":{"smooth","eq","jump"},
 "haze":{"col","colAt","row","rowAt"}, "dhash", "phash", "dupOf":[files], "flags":[...]}
```

NaN (no defined value, such as a flat image) is `null`. `{"dup":{"a","b","dhash","phash"}}` lines at the end list
every near-duplicate pair of the batch (both hashes within `dthr`/`pthr`, default 10 bits).

## Numbers (ops of `mojo-cv`, all uint8; wrong channels or too small raise)

| op | output | definition |
|---|---|---|
| `sharpness tile thr` | lapvar, tenengrad, softTiles | variance of the 4-neighbour Laplacian; mean Sobel gx^2+gy^2; share of full `tile` blocks of the Laplacian with variance below `thr` (interior pixels) |
| `noiseEst` | sigma, nbr | Immerkaer sigma; mean abs difference of adjacent pixels (the ComfyUI static pre-filter: static 26.7, photo 3 to 6 at a small size) |
| `blockiness` | Bh Nh Bv Nv ratio | mean abs difference across 8-px block edges over elsewhere; native size only |
| `clipping lo hi` | lo, hi, p01, p99, mean, std | share of pixels <= lo and >= hi, percentiles by cdf |
| `colorCast` (BGR) | B G R, R-G, B-(R+G)/2 | gray-world; a legitimately blue scene reads as cast too |
| `banding btile bstd brange` | smooth, eq, jump, n | over smooth tiles (range >= brange, std <= bstd): equal-pair share and share of unequal pairs jumping 2+ levels |
| `hazeBand` | col, colAt, row, rowAt | weakest of 4 column (row) strips by Sobel energy over the median strip |
| `hashes` | 2 x 64 bits | dHash (8x9 box means) and pHash (32x32 box means, orthonormal DCT, 63 AC bits) |
| `hamPairs thr` | M x 3 int32 | all pairs of N 64-bit rows within `thr` |
| `clipRegion lo hi` | 8 numbers | largest 8-connected region of pixels >= hi and of pixels <= lo: area share, box width and height share, region count |
| `hysteresis lo hi min_area connectivity` | mask | regions of (src > lo) that reach above hi and cover at least min_area (seeded threshold) |
| `boxDown f` | image | integer area shrink, rounded mean |
| `stockMetrics ascale` | 37 numbers | everything above for one BGR image; sharpness, noise, clipping, banding and haze run on the grey image shrunk by `round(long edge / ascale)` (default 1536) so one threshold fits 1280 px and 6144 px files; blockiness and hashes run native |

Each is checked against numpy/cv2 on the same definition (`tests/cases/stock.txt`, 109 rows, `eqnan` = NaN only where the
oracle has NaN), with planted failures (`tests/stock_planted.sh`) and malformed inputs (`tools/malformed_check.py`).

## Flags and thresholds

Placed just outside the range of the 46 pictures Adobe accepted from `doar-bio-stock` (128 files, 21 MP, labels from
`~/Brain/gpu-media/doar-bio-stock/2026-11-13-adobe-review.md`); override with `k=v`.

| flag | rule (default) | accepted flagged | planted caught |
|---|---|---|---|
| `lowres` | mp < 4 (`minmp`) | 0 of 46 | all 1080p fixtures |
| `blur` | lapvar < 15 (`blurlap`) | 0 of 46 (accepted min 19) | blur |
| `noise` | sigma > 6 (`noisesig`) | 0 of 46 (max 2.98) | noise (9.4) |
| `blocks` | ratio > 2.0 (`blk`) | 0 of 46 (max 1.73) | JPEG q8 (2.45) |
| `banding` | smooth >= 0.05 and eq > 0.85 and jump > 0.7 (`bandmin bandeq bandjump`) | 0 of 46 | banded ramp, JPEG q8 |
| `clipHigh` / `clipLow` | hi > 0.10 / lo > 0.50 (`cliphi cliplo`) | 0 of 46 | blown (0.28), salt noise (0.12) |
| `blownVoid` | largest region of clipped-high pixels > 8 % of the picture (`voidhi`) | 0 of 46 (max 4.5 %) | blown ramp (10 %); scattered 12 % clip: 0.001 % |
| `cast` | abs(R-G) > 35 or abs(B-(R+G)/2) > 60 (`castrg castby`) | 0 of 46 | cast |
| `flatStrip` | weakest strip ratio < 0.001 (`flatstrip`) | 1 of 46 | white-out |
| `duplicate` | dHash and pHash both <= 10 bits (`dthr pthr`) | 0 | JPEG q95/blur/noise/cast twins |

## What this does not catch (measured)

The seven Adobe quality refusals in that set (soft grape cluster, malformed blossoms, fog band, floating stall, dull cows,
stray camera, pseudo-text labels) are semantic. Measured on the same files, none of sharpness (lapvar at 1536 px 267 to
1684 against an accepted median 201), noise, blocks, banding or clipping separates them from the accepted pictures.
Only db067's white-out shows, as the flattest strip of the set (ratio 0.0008; one accepted picture is as flat, 2 of 46 fall below 0.002 and 8 below 0.005); `flatStrip` keeps
that at 1 of 46 false positives, but 15 of the 82 other files trip it too (dark or blank backdrops) and a mild haze
(75 % blend, ratio 0.05) passes: it is a prompt to look, not a verdict. Saturated subjects ("similar content", 18 of 25
refusals) are about Adobe's collection, not pixels. Hands, text and face artefacts need a detector (phases 2 and 3).
Sources: `docs/sources.md`.

## Speed (4202 images, 6.6 GB, 16.2 MP in total; `~/Projects/imports/ComfyUI-v0.43.0/output`, 8 decode and 8 analysis workers)

| step | before | after | what changed |
|---|---|---|---|
| analysis of one 21 MP BGR image (`stockMetrics`, one thread) | 319 ms | 46 ms | block-edge sums with 16/32-lane SIMD (110 to 1.3 ms), channel means in one pass (165 to 6.5 ms) |
| decode of a 21 MP JPEG / 21 MP PNG | 0.67 s / 1.08 s (ImageMagick) | 0.24 s / 0.28 s (libvips, 1 thread) | `scripts/decode-stock.sh`: vips for 8-bit RGB without an embedded profile, ImageMagick for alpha, grey, 16-bit and ICC; same pixels (checked on 22 of 24 sampled files, the 2 others are RGBA cutouts, which take the ImageMagick path) |
| `mat.load` of a 62 MB file | byte loop | `unsafe_memcpy` | whole `stockMetrics` process 0.47 s to 0.17 s |
| whole library | 263 s (16.0 img/s, 61.8 MP/s, RSS 1.88 GB) | 147 s (28.5 img/s, 110 MP/s, RSS 1.87 GB) | output identical: 0 differing rows of 4202, same 3685 duplicate pairs |

Decode of the next chunk overlaps the analysis of the current one (`MCV_OVERLAP=0` turns it off): 14.4 s and 14.9 s against 17.0 s and 15.8 s on 700 images, measured at a load average of 27 from other work on the machine, so treat it as about 10 %. The wall times above the overlap row were taken before it existed.

## Faces (`--faces`, phase 2)

`scripts/mcv-stockcheck --faces ...` runs `.bin/mcv-faces` (`src/stockfaces.mojo`) over the original files: SCRFD from `~/Projects/mojo/mojo-faces`
(imported with `-I`, not copied; `mojo-faces` itself imports `mojocv`, so the stage is a separate binary, not part of the `mojocv` package) through its GPU
runner under `gpu-wait`. Build: `mojo build -O3 -I src -I ../mojo-faces/src -I ../mojo-imkit/src -I ../mojo-mmap/src src/stockfaces.mojo -o .bin/mcv-faces`
(`tests/stock_faces.sh` does it). Model: `MCV_FACES_MODEL`, default buffalo_l `det_10g.onnx`.

Added to each line: `faces:{n, largest, score}` (`largest` is the biggest face box over the picture area, upright as shown), `platforms:{adobe, dreamstime}`,
`faceReview`, and the flag `face`. Our assets are AI-generated, so no model release is involved; the face only routes the picture: Adobe accepts fictional
AI people (tick "people are fictional", no real likeness), Dreamstime refuses generated faces (back views and body parts are fine, FAQ 4623), so a face means
`dreamstime:false` and `faceReview:true` for the human look at eyes, teeth and nearby hands. The review itself is not measured here.

Gates (`tests/stock_faces.sh`, GPU, not in `ci.sh`): on the 55 mojo-faces test photos mojo-cv's `mcv-faces` equals insightface (51 faces, boxes IoU 1.0000 on the CPU
runner and 0.9997 on the GPU runner, landmarks within 0.02 % of the box, same upright pixels via `tools/cmp_faces.py`); end to end, db044 (refused by Dreamstime for a
face) gets `face`, `dreamstime:false`; db000 gets neither; the sidecar equals the output line.

Measured on the 128 doar-bio files (21 MP): the 4 pictures Dreamstime refused for faces (db044, db048, db062, db065) are all detected (recall 4 of 4, db065's face
is 0.13 % of the frame at score 0.57); 2 of the 42 pictures Dreamstime accepted also carry a detection (db080, 0.4 % of the frame; db084, 0.17 %), so routing every
face to Adobe over-routes about 5 % of the safe set and no size threshold separates them (db065 is smaller than both). The 128 files took 93 s (decode-bound: the
GPU detects in about 12 ms; JPEG decode of a 21 MP file takes most of the rest).

Grey, palette, 16-bit and interlaced PNGs are refused by mojo-faces' loader (3.1 % of the AssetsHQ library, 232 of 7592, per cvint). `mcv-faces` also reads `.ppm` and `.mcv` files, and
`mcv-stockcheck --faces` retries every picture that came back with a face-stage error through `scripts/decode-stock.sh` (vips, ImageMagick for what vips does not take) and puts the
result back under the original name; one that still fails keeps its error. Gate: `tests/stock_faces.sh` makes the four kinds of PNG from one face picture, shows that `mcv-faces` alone refuses
some of them (the control), then finds the face in all four through the retry.
