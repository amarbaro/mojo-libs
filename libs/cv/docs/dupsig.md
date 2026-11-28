# dupsig: duplicate signatures of 3D assets

One 3D model sits in a library as glb, fbx and blend, as LODs, re-exports and regenerations under different sha256 values; byte hashes and
`stockDups` (images only) never relate them. `viewSig` and `sigPairs` (`src/mojocv/dupsig.mojo`) relate them from the fitted ortho view
picture and the geometry numbers a library already measured.

## viewSig

`scripts/mcv-visualcheck` with `MCV_OP=viewSig` (same decode and chunking as `visualCheck`) or `mojo-cv viewSig OUT.tsv BATCH.tsv [scale=256 thr=30]`
on decoded `.ppm` files. One row per picture: path, bounding-box aspect, mean object colour (r g b), a 24 x 24 grid of object coverage over
that box, a 24 x 24 grid of luma divided by the object's mean luma. The object is what departs from the backdrop (median of the 2 px border,
summed absolute channel difference >= `thr`). Position, scale, colour and brightness are free; silhouette and shading structure are not.
A sheet with no object gives `path<TAB>empty`, an unreadable one `path<TAB>fail <reason>`.

## sigPairs

`mojo-cv sigPairs OUT.tsv IN.tsv [iou=.985 shade=8 dim=.15 asp=.15 gtol=.02 giou=.6 lou=.85 lsh=15 ldim=.05 lcd=30]`. IN rows:
`id tris verts bx by bz textures texpx aspect r g b occ shade` (picture columns `-` where the asset has no sheet). One output row per pair
that is one model: `id_a id_b rule iou shade aspect_ratio colour_distance`. Rules, in order:

| rule | holds when | catches |
|---|---|---|
| `view` | silhouette IoU >= iou, shading diff <= shade, box aspect and sorted bbox dims within .15 | re-exports, LODs, re-colours: the triangle count is free |
| `geo` | triangles and vertices within 2 %, sorted bbox dims within 2 % of the longest, same texture count and size; with two sheets the IoU must still reach .6 | the same mesh in another unit or axis order, assets with no sheet |
| `look` | IoU >= .85, shading <= 15, dims and aspect within .05, same texture count and size, mean colour within 30 | one generator recipe, regenerated (bench, apple: 3 to 14 % of silhouette differs) |

Thresholds come from Mario's sample of 2026-11-28 (bench x6, apple x2, stacked chair x2, wedge barrel x3): inside a group IoU .86 to 1.0,
across groups at most .85 apart from apple against barrel (.85); a sweep over the 3,904 library rows showed IoU .90 joining 82,000 pairs
into a 474-member cluster of barrel-like cylinders. UNVERIFIED beyond that sample: no labelled negative set exists.

## Test

`tests/dupsig.sh` (6 checks on planted pictures): a colour variant (other hue, 80 % size, shifted) pairs by `view` with colour distance 76;
a LOD (same picture, 40 x triangles) pairs by `view`; a notched copy pairs by `look`; two rows without pictures pair by `geo` after a unit
change and not when the texture size differs; a star and a striped copy pair with nothing; the pair count is exactly 6.
