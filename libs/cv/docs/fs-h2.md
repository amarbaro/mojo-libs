# fs-h2: H2 fixtures for the S2 ops lane (P0)

Generator: `tools/fs-h2/gen.sh` (seeded, PIL 13 + numpy 2.5, deterministic). Re-run regenerates all of `tests/fixtures/fs-h2/` except `screens/`.
Manifest: `tests/fixtures/fs-h2/SHA256SUMS` (`sha256sum -c` clean, 41 files).

## Contents

| set | files | ground truth | used by |
|---|---|---|---|
| stream pairs | `stream/A.png`, `stream/B_changed_tile.png`, `stream/C_same.png` (zero-change control), `stream/{A,B}_q{95,85,75,50,30}.jpg` | `stream/pairs.json`: one changed 64 px tile at col 3, row 2, box `[192,128,256,192]` (asserted to be the only differing region); lossless diff px count; PSNR of each JPEG vs its source (CPU decode) | R3, R4 absdiff/stream |
| dialogs | `dialogs/dlg_de_light.png`, `dlg_en_dark.png`, `dlg_small_light.png` | `dialogs/dialogs.json`: every title, body line and button with exact `box_xyxy`, role, clickable; German umlauts and ß included; dark and light themes | R13, R20 screen parser |
| annotated screens | `screens/screen_01..10.json`, `screens/INDEX.tsv` | element boxes, role, clickable; text redacted | R13, R20, R21 |
| mattes | `mattes/{shirt_thin,pants_gap,jacket_sleeves,shirt_lowcontrast}` + `{empty_hanger,empty_bg}`, each `.png` + `.mask.png` | `mattes/mattes.json`: labels 0 background, 1 cloth, 2 hanger (3 px strap, always present); pixel counts; boundary band (2 px) size; empty-cloth flag | R7 GrabCut matte |

## Status of each item (no BLOCK hidden as PASS)

- **Stream pairs, JPEG sweep:** complete. Generated, not captured from a camera.
- **Dialogs:** complete, synthetic. Boxes are the exact draw coordinates, so they are ground truth by construction. Real imkit output is not covered.
- **Annotated screens:** PARTIAL. Ten real captures were read from `~/Projects/ebay.de/.work/shots/` (existing captures; no new spectacle or CDP capture was taken). Annotations are an auto draft: tesseract `--psm 11` word boxes grouped into lines, role `button` and `clickable` from a label-word list, everything else `text`. Not human-verified. Element counts range 19 to 104 per screen; 0 clickable in 8 of 10. Treat boxes as OCR output, not truth.
  - Privacy: the captures come from the seller account. Only redacted JSON (`<redacted:N>` text, boxes, roles) is committed. Private copies with text stay in `.work/fs-h2/screens/` (gitignored). Also `text_redacted: true` in each JSON.
  - Languages: not recorded per screen. The set covers whatever languages the captures contain; no per-UI-language balance was checked.
- **Mattes:** SYNTHETIC ONLY. `~/Projects/ebay.de/.work/stock-20261122/work/` holds photos (`IMG_*.jpg`) and no mask labels, so no real labelled matte exists there. The real-matte row remains BLOCK until a labelled set is supplied. Each synthetic matte has a thin class-2 strap and a 2 px boundary band. Empty cloth is covered by two cases.
- **Hashes:** every file in the set is in `SHA256SUMS`.

## Not covered

- Real JPEG captures from the phone or camera (H5 scope).
- Decoder oracle values: JPEG decode is CPU PIL only, as required. No Mojo decode run was done here.
- Mojo consumption of these fixtures: nothing was run against `mojocv`. This doc is a fixture spec, not a pass.

## Regenerate

```
cd ~/Projects/mojo/mojo-libs/libs/cv && bash tools/fs-h2/gen.sh
```

The screens step is a one-off OCR pass over private captures. It is not part of `gen.sh`, because `gen.sh` must not read private data.

## Extension: absdiff, resize, stream tile truth (R3a, R3b, R4)

Generator: `tools/fs-h2/gen_refs.sh` (run after `gen.sh`; refuses to run unless the P0 `SHA256SUMS` verifies). Deterministic, PIL 13 + numpy only.

| set | files | ground truth | used by |
|---|---|---|---|
| 16 px and border tiles | `stream/B_px16.png` (changed 16 px cell at col 21, row 16), `stream/B_border16.png` (bottom-right 16 px cell, col 39, row 27) | `stream/absdiff_ref.json`: changed region asserted to be exactly the block | R4 border and 16 px cases |
| tile dirty reference | `stream/absdiff_ref.json` | per pair: max abs diff, nonzero px, dirty tiles on the 64 px and 16 px grids at frozen threshold 16, per-tile max on the 64 px grid | R4 mask, R3a absdiff |
| absdiff twin | `stream/absdiff_A_vs_B_changed_tile.png`, `stream/absdiff_twin.json` (kind integer, exact) | lossless PNG of |A - B| (max over channels) | R3a integer twin, byte-equal gate |
| resize twin | `resize/{A_320x224,A_400x280,A_1280x896,B_changed_tile_400x280}_bilinear.png`, `resize/resize_ref.json` (kind float) | PIL BILINEAR, reducing_gap=None; raw RGB sha256 and PNG sha256 | R3b float twin; tolerance set by S2 from measurement |

Hashes: `tests/fixtures/fs-h2/SHA256SUMS` covers all 52 files.

### Measured on the fixtures (threshold 16, not tuned)

- `A_vs_B_changed_tile`: 1 dirty tile on the 64 px grid (`[2,3]`), 16 dirty 16 px cells, 4096 changed px.
- `A_vs_B_px16`: exactly one 16 px cell (`[16,21]`). `A_vs_B_border16`: exactly one (`[27,39]`).
- `A_vs_C_same`: zero dirty tiles on both grids.
- **JPEG sweep does not give zero tiles against the lossless source.** `A_vs_A_qN` (N = 30..95) has max abs diff 130 to 150 and flags all 70 of 64 px tiles and all 1120 of 16 px cells. This is codec noise on the high-frequency test texture (4:2:0), not motion. The plan's R4 contract ("a fixed JPEG-quality sweep gives zero tiles") therefore must compare two decodes of the same JPEG setting (`A_qN` vs `A_qN`, both CPU decoded), or a smoothed source, or a threshold measured on the accepted set. Not decided here: the threshold and the comparison pair are S2 and boss calls. The reference holds the measured numbers so either choice can be checked.

### Not covered

- No Mojo run against these fixtures; this is a reference spec, not a pass.
- JPEG decode is CPU PIL only. No GPU arm is referenced.
- Resize tolerance is not set here; the float twin has no pass bar yet.

## P2 extension: stuck states, planted disc, planted EVM signal (R13a, R13b with R20a, R7, R3c)

Generator: `tools/fs-h2/gen_p2.sh` (run after P0 `gen.sh` and `gen_refs.sh`; refuses unless the P0 `SHA256SUMS` verifies). Output: `tests/fixtures/fs-h2/p2/`, hashed in `p2/SHA256SUMS` (15 files). Truth: `p2/p2.json`.

| set | files | ground truth | used by |
|---|---|---|---|
| stuck states | `p2/stuck/modal_{A,B}.png` (dialog fixed, background changes), `video_{A,B}.png` (region changes), `cursor_{A,B}.png` (3 px cursor toggles) | `p2.json` `stuck`: dialog box, element list (role, box, text, clickable), changed bbox, expected stuck and progress flags | R13 stuck oracle: modal over changing background is stuck; playing video is not; blinking cursor is not progress |
| dialog elements | the `modal_A.png` element list (title, body, two buttons, umlauts included) | exact draw boxes | R13b and R20a separate box, role, text, clickability |
| planted disc | `p2/mattes/disc.png` + `.mask.png`, `disc_hole` (6x6 hole), `disc_empty` (background only, all-zero mask) | labels 0 background, 1 disc, 2 boundary band (2 px); counts; empty flag | R7 falsifier: planted disc before any upsampler; empty cloth gives no mask |
| planted EVM signal | `p2/evm/planted_sin.npy` (40 frames, 64x96 uint8, 0.1 cycles/frame, 2 levels, 16x24 patch), `p2/evm/static.npy` (zero-change control) | `p2.json` `evm`: freq, amplitude, patch slices, measured peak to peak | R3c temporal gain check, static control must stay byte-equal |

## Not done (BLOCK, not PASS)

- **Nine labelled hand photos (R7):** NOT present. No labelled hand mask set exists in `~/Projects/ebay.de/.work/stock-20261122/` (only unlabelled `IMG_*.jpg` and `box-on-hand.png`). Not fabricated. Gate `H2-p2-hands` writes BLOCK until `.work/fs/labels/hands/` holds the nine labelled photos from Mario.
- **Annotated screens per UI language (R20a):** not extended. The P0 set is still PARTIAL (auto OCR draft, unverified, no per-language balance recorded). No new captures were taken.
- **Real labelled mattes:** still synthetic only (P0 status unchanged).
- Mojo consumption of any P2 fixture: nothing run against `mojocv`. This doc is a fixture spec, not a pass.

## Regenerate

```
cd <worktree>/libs/cv && bash tools/fs-h2/gen.sh && bash tools/fs-h2/gen_refs.sh && bash tools/fs-h2/gen_p2.sh
```
