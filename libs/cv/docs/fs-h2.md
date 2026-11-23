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
