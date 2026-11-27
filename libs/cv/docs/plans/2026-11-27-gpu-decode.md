# Plan: GPU decode + resident stock ops (step 3 of 4), 2026-11-27

Goal: `stockBatch gpu=1` decodes each JPEG to DCT coefficients on the CPU (libjpeg-turbo Huffman, the only serial part),
uploads them once, and runs dequantise, IDCT, upsample, colour and every `stockMetrics` op on the GPU; only the 37 numbers and
two hashes come back. Step 4: the CPU path (`jpegio.mojo`, commit 4e99c700) stays the default until this one wins end to end.

## Numbers to beat (docs/gpu.md, "Decode first")
- CPU path now: 147 ms per 21 MP picture per core (decode 51 + analysis ~96); `mcv-stockcheck -j 14`, 406 mixed images: 10.9 s.
- Floor of the GPU design: Huffman about 35 ms per picture per core (djpeg -scale 1/8 lower bound); everything after it on the GPU.
- Rule 34: a GPU stage in front of a parallel CPU stage lost 2.2x once. Measure end to end on the same files before keeping anything.

## Steps (each one committed with its receipt)
1. Coefficients out of libjpeg-turbo, CPU only. Options, cheapest first:
   a. `tj3Transform` with a `customFilter` callback (receives each component's coefficient blocks); needs a C-callable Mojo
      function pointer: probe that first (10-line test).
   b. libjpeg API `jpeg_read_coefficients` through FFI: `jpeg_decompress_struct` layout for libjpeg-turbo 3.2.1 (LP64) taken from
      `jpeglib.h`, size checked against `sizeof` printed by a 5-line C probe; error manager with longjmp avoided by
      `TJPARAM_STOPONWARNING`-like checks or a C shim if needed (ask before adding C).
   Gate: CPU IDCT (port of jidctint.c ISLOW) + jdsample fancy upsample + jdcolor from those coefficients equals tj3Decompress8
   byte for byte on the 20-file corpus and the planted JPEGs.
2. GPU kernels (read the AMD/RDNA skill first, amd_docs_gate): dequant+IDCT per 8x8 block (one block per thread or 8 threads per
   block, int32, bit-exact to the CPU port), h2v2 fancy upsample, YCbCr->BGR, then grey and the existing twins (boxDown, sharpness,
   Sobel) on the resident image. Gate: tests/cases_gpu rows + bytes of the decoded image equal the CPU port.
3. Port the rest of `stockMetrics` to read the resident image (noise, blocks native, clip + clipRegion, cast, banding, haze,
   hashes); unported ops may download the analysis-scale image (1536 px, 1.3 MB) instead of the full one.
4. Batch: N pictures in flight (CPU Huffman on 13 cores, one GPU queue), `gpu-wait run --timeout S --mem GB`, wavewait on the
   kernels, heaptide not on the GPU process (rule 35: RSS from /usr/bin/time, VRAM sampled).
5. Gate for keeping it: `mcv-stockcheck -j 14` on the same 406 images and on the 4,601-image library: identical lines to the CPU
   path and lower wall time. Else document the numbers here and delete the stage (rule 34).

## Files
`src/mojocv/jpegcoef.mojo` (coefficients), `src/mojocv/gpu.mojo` (+ decode kernels), `src/mojocv/stockcheck.mojo` (gpu=1 batch),
`tests/cases_gpu/`, `tests/stock_planted.sh` (gpu arm), `docs/gpu.md` (receipt), `docs/rules.md` (any mistake).

## Measured before building (same day, one core, 8 x 21 MP, bench_ops)
decode (tj3, full) 55 ms; full-size ops: grey 8, boxDown 6, blockiness 1, colorCast 7, hashes 12 (34); analysis-scale ops:
clipRegion 21, banding + haze 5, sharpness 4, noise 2, clipping 0 (32). Total about 121 ms.
- Movable in the first GPU cut: decode tail (upsample + colour, about 15 of the 55; Huffman + IDCT stay on the CPU through
  `tj3DecompressToYUV8`) plus the 34 ms of full-size ops: ceiling about 1.7x per core. With every analysis op ported as well
  (clipRegion = connected components, the hard one): about 3x.
- First cut therefore: `tj3DecompressToYUV8` -> upload planes -> h2v2 fancy upsample + jdcolor YCC->BGR (bit-exact) -> grey ->
  boxDown + colorCast sums + hash box means on the GPU; download only the analysis image (1.3 MB) and the sums; blockiness on the
  native grey stays CPU unless measured worth it.
- Cheaper win on the CPU first: clipRegion is 21 ms on the 1536 px image alone (17 % of a picture).

## Result of the first GPU cut (2026-11-27, branch cv/gpu-stock)
Built as planned above (planes from `tj3DecompressToYUVPlanes8`, not coefficients: step 1 was skipped, the IDCT stays in libjpeg).
Gates in `tests/stock_gpu.sh`: BGR bit-exact to tj3Decompress8 on 28 of 28 JPEGs; `mcv-stockcheck gpu=1` lines byte-identical to the
CPU path (437 lines); end to end on the 406-image set, `-j 14`, 6 interleaved rounds: CPU mean 10.94 s, gpu=1 mean 9.73 s (-11 %,
6 of 6 rounds). Measured on a PCIe link trained at 2.5 GT/s (3.6 GB/s copies: 8.8 ms per 21 MP picture of planes, kernels 1.4 ms).
Detail and what did not pay: `docs/gpu.md`, "stockBatch gpu=1". The CPU path stays the default until the 4,601-image library run
(step 5) is done. Next lever by the numbers: the analysis-scale ops (32 ms of the 75 ms CPU left per GPU picture, clipRegion 21),
then a re-measure on a full-speed link.
