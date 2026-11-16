# assets-cv report

## Phase 1: stockcheck (2026-11-16)

mojo-cv now checks a stock batch at 28.5 images/s (4202 ComfyUI renders in 147 s, 263 s before), and the checks catch every
technical failure we planted. They do not catch what Adobe actually refused: 24 of its 25 refusals in the doar-bio set are
semantic (similar content, anatomy, pseudo-text), and no pixel number separated the 7 quality refusals from the 46
accepted pictures except one white-out fog band, at a false-positive cost.

### What landed (commits 2dfbd05, d8277e0, f3d012d, f084389)

- `src/mojocv/stockcheck.mojo`, 13 ops: `sharpness`, `noiseEst`, `blockiness`, `clipping`, `colorCast`, `banding`,
  `hazeBand`, `boxDown`, `hashes` (dHash, pHash), `hamPairs`, `stockMetrics` (29 numbers per image), `stockBatch`
  (parallel, one JSON line per image), `stockDups` (near-duplicates over the whole batch). Docs `docs/stockcheck.md`.
- `scripts/mcv-stockcheck OUT.jsonl IMAGE|@LIST...` with `--sidecar` (writes `IMAGE.stockcheck.json` beside each image).
  Flags: `lowres blur noise blocks banding clipHigh clipLow cast flatStrip duplicate`; thresholds are `k=v` overrides.
- Decoder `scripts/decode-stock.sh`: libvips for 8-bit RGB without a profile, ImageMagick for alpha, grey, 16-bit, ICC.

### Gates

| gate | result |
|---|---|
| `tests/cases/stock.txt`, every op against numpy/cv2 on the same definition | 109 of 109 rows |
| full 2D suite after the changes (`tests/run.sh`) | 396 of 396 rows |
| `tests/stock_planted.sh`: each planted failure raises exactly its flag, clean images none, twins pair, decoders agree | all pass (20 flag/dup checks, vips = magick on 4 images) |
| `tools/malformed_check.py`: wrong channels, tiny images, bad hashes, 7 bad `.ppm` files, unreadable files | 40 ok; 2 glb rows fail on the 29 Oct `mojo-cv3d` binary, untouched by this work |

### Numbers

- Library, 4202 images, 6.6 GB: 263 s, RSS 1.88 GB before; 147 s, RSS 1.87 GB after; output identical row for row.
- One 21 MP image: analysis 319 to 46 ms (blockiness 110 to 1.3, colorCast 165 to 6.5), JPEG decode 0.67 to 0.24 s.
- Measured at load average 27 from other lanes: the 10 % overlap gain is rough.
- Calibration on 128 real files (46 Adobe-accepted): thresholds sit outside the accepted range; 0 of 46 flagged except one
  `flatStrip`. Planted: blur lapvar 3 (clean 1176), noise sigma 9.4 (2.8), JPEG q8 blockiness 2.45 (1.02), banding jump 0.88 (0.06),
  blown 28 % clipped, cast R-G 37, white-out strip 0.0003; every near-copy of one scene is a duplicate pair (dHash 0 to 4, pHash 0 to 2 bits).

### What failed or is missing

- Item 3 (AI-artifact cues): hands, text and anatomy are not visible to sharpness, noise, banding or clipping. db019 "soft
  detail" measured lapvar 316 at 1536 px, above the accepted median 201. `flatStrip` is a prompt to look: it catches db067
  (ratio 0.0008), misses a 75 % haze, flags 1 of 46 accepted and 15 of the 82 other files.
- "Similar content" (18 of 25 refusals) concerns Adobe's collection, not our pixels; the batch duplicate check only stops our own twins.
- BRISQUE and NIQE not built (need a trained natural-scene model that is not in the repo); the PaperBrain vault holds no image-quality
  papers (queries returned unrelated mathematics), so `docs/sources.md` cites the original methods instead.
- `stock-review` and `bulk-stock-tag` do not read the sidecars yet; I did not touch those repos.
- Thresholds come from one site's accepted set (Adobe, 46 pictures at 21 MP). Other sites and sizes need their own set.
- Mistakes recorded: `docs/rules.md` 5 to 8, `~/Brain/SINDEX/mojo-cv.md`.

## Phase 2: faces (commit 8d76221)

`mcv-stockcheck --faces` adds the face count, the largest face's share of the picture and platform routing to every line: a face means
Adobe only (people fictional) and a face-quality review flag, because Dreamstime refuses generated faces. SCRFD comes from
`mojo-faces` by import (`src/stockfaces.mojo`, a separate binary because `mojo-faces` itself imports `mojocv`), through its GPU runner.

| gate | result |
|---|---|
| mojo-faces' 55 test photos against insightface (`tools/cmp_faces.py`, boxes IoU >= 0.99, landmarks within 1 %, same upright pixels) | 51 faces, IoU 1.0000 (CPU runner), 0.9997 (GPU runner), kps 0.0002 |
| `tests/stock_faces.sh` end to end: db044 (Dreamstime refused its face) and db000 (none) | face flag, `dreamstime:false`, `faceReview:true` for db044; both platforms for db000; sidecar equals the line |

Measured on the 128 doar-bio files: all 4 Dreamstime face refusals detected (recall 4 of 4; db065's face is 0.13 % of the frame); 2 of the
42 Dreamstime-accepted pictures also carry a detection (db080 0.4 %, db084 0.17 %), so routing every face to Adobe over-routes about 5 % of
the safe set and no size threshold separates them. 128 files of 21 MP took 93 s, decode-bound (GPU detection about 12 ms).
Not measured: the face-quality review itself (eyes, teeth, nearby hands) is only routed to a human. The gate needs the GPU and the private test photos, so it is not in `scripts/ci.sh`.

## Phase 3: SigLIP

Not started. Needs the transformer ops in `GpuNet` (LayerNorm, Softmax, MatMul, GELU, attention) gated against onnxruntime.

### Phase 3 status (2026-11-16, not done)

The SigLIP vision tower runs on mojo-faces' CPU runner and equals onnxruntime; the GPU port, the text tower and the labels are still open.

| piece | state | receipt |
|---|---|---|
| model | `onnx-community/siglip-base-patch16-224-ONNX` (Apache-2.0) at `~/Models/siglip-base-patch16-224-onnx/onnx/model.onnx`, 813080024 B, one graph with both towers; no tokenizer files in that repo | HF API listing, size from the HF header |
| op inventory | 14 op types missing from the runner, 1036 vision nodes | `.work/siglip_ops.md` (cvhelp) |
| CPU ops | MatMul (batched), LayerNormalization, Softmax, Tanh, Exp, ReduceL2, Div, Constant, Cast, Squeeze, Expand, Tile, ConstantOfShape, Mod, float Gather/Unsqueeze/Slice, general broadcasting; `run(targets)` runs only what a value needs | mojo-faces 201a2a2 |
| gate | `tests/check_siglip.sh`: 15 intermediate values (1 to 2 per op type) against onnxruntime: all cosine 1.0000000, `image_embeds` max abs 1.8e-7; 7.7 s per image on the CPU; ArcFace/SCRFD gate unchanged (cosine 1.0000000) | `.work/siglip/` in mojo-faces |
| GPU ops | not built. At 7.7 s per image the 4202-image library needs 9 h on the CPU; brief: `docs/lanes/2026-11-16-gpunet-transformer-brief.md` | |
| text tower, labels, embedding duplicates | not built. The graph has the text tower, but tokenization needs SentencePiece and its model file (not in the ONNX repo, `sentencepiece` not installed) | |
| `assets.db` columns | not written: `~/Projects/AssetsHQ/docs/schema.md` does not exist yet (only `plan-library.md`) | |

Added from cvint's note: `Gather` on axis 1 (SigLIP text last token) and a tiled CPU `gemm` are on the GPU-port list (`docs/lanes/2026-11-16-gpunet-transformer-brief.md`);
the face stage now decodes grey, palette, 16-bit and interlaced PNGs through `scripts/decode-stock.sh` (`src/stockfaces.mojo`, retry in `scripts/mcv-stockcheck`), gate `tests/stock_faces.sh`, result pending in the GPU queue.
