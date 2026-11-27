# GPU path (MAX, gfx1100)

Five ops have a GPU twin in `src/mojocv/gpu.mojo`: grey (`cvtColor` bgr2gray, rgb2gray), integer area shrink (`boxDown`),
sharpness (`sharpness`: Laplacian variance, Tenengrad, soft tiles), `Sobel` 3 x 3, and `crop`. `mojo-cv OP OUT IN... gpu=1` takes the
GPU; the CPU op stays the default and is the answer whenever a parameter is outside the kernel (other `ksize`, `scale`, a float or int16
input, a colour code that is not grey) or no accelerator is found (`HIP_VISIBLE_DEVICES=-1` prints `gpu: no device`, then the CPU
output). Every kernel is integer arithmetic in the CPU op's order, so the output is the CPU output byte for byte.

## Same oracle rows

`tests/cases_gpu/gpu.txt` holds 25 of the CPU rows (cv2 5.0 or numpy oracle, the CPU row's tolerance) with `gpu=1` appended:
`tests/run_gpu.sh` runs them in one gpu-wait job: 25 of 25 pass, 10 `exact` (maxdiff 0.0), 13 sharpness rows `eqnan:1e-6`, and
the two float rows, which the CPU op answers (the kernels are uint8). One row failed on the first run: the grey kernel used the 14-bit weights of older
OpenCV (1868, 9617, 4899), the CPU op and cv2 5.0 use 15 bits (3735, 19235, 9798): maxdiff 1 on `cvt_gray_hd`. Crop is checked
GPU = CPU = a numpy slice; the hidden-GPU run writes the CPU file. `tests/run.sh` (the 2D rows, CPU) does not read `tests/cases_gpu`.

## Speed: where the GPU wins and where it does not

`tests/bench_gpu.sh`: best of 10 runs in one process, 7900 XTX, every GPU time includes the upload and the download, bytes of both
outputs identical in every row.

| op | input | CPU ms | GPU ms | CPU / GPU |
|---|---|---|---|---|
| sharpness | 50 MP grey | 187.1 | 12.1 | 15.5 |
| sharpness | 1080p grey | 7.58 | 0.70 | 10.9 |
| boxDown f=4 | 50 MP grey | 14.8 | 2.04 | 7.2 |
| boxDown f=4 | 1080p grey | 0.567 | 0.168 | 3.4 |
| crop (quarter) | 50 MP BGR | 68.3 | 7.06 | 9.7 |
| crop (quarter) | 1080p BGR | 2.80 | 0.388 | 7.2 |
| cvtColor bgr2gray | 50 MP BGR | 3.91 | 7.33 | 0.5 |
| cvtColor bgr2gray | 1080p BGR | 0.087 | 0.394 | 0.2 |
| Sobel dx | 50 MP grey | 4.66 | 6.01 | 0.8 |
| Sobel dx | 1080p grey | 0.216 | 0.360 | 0.6 |

The ops that read a lot per pixel (the 9-tap sharpness, the f x f shrink) win; the one-pass ops (grey, Sobel) are bound by the copy of the
picture and the CPU's vector code beats them. The per-photo gain of the winners is 10 to 20 ms, small against the decode that dominates
the stock job: 3.0 s per 50 MP iPhone JPEG on the CPU (4 photos in 12.2 s, the ImageMagick path of a photo with an ICC profile; the VCN
`jpeg_dec` ring is not used, it reset three times on these files). A batch stage on top of them did not pay (next section).

## What did not pay: the GPU inside `stockPhoto`

`stockPhoto gpu=1` (area shrink and sharpness of photos of 4 MP or more on the GPU, in a serial pass before the parallel CPU stage)
was built, measured and deleted. Six 50 MP photos, 8 passes (48 photos), same output bytes: 9.5 s and 3.26 GB peak RSS on the CPU,
20.8 s and 4.55 GB with the GPU pass. The pass loads each photo a second time, runs grey, hashes and clip shares serially and holds the
MAX runtime (+1.3 GB), where the CPU stage spreads all of it over 8 cores; the 10 to 20 ms the kernels save per photo do not cover that.
The kernels stay as `gpu=1` ops for callers that run one big picture at a time (the table above), not as a stage of the batch.
A pinned staging buffer instead of a copy from the List's memory was tried as well and halved the GPU speed (sharpness 12.1 to 23.2 ms
at 50 MP) without changing anything else, so it was reverted.

## Profile with the trio

- **heaptide (RAM)**, CPU path, 240 photos of 50 MP under `triwait --no-gpu`: no leak (direct 0 B, indirect 0 B), growth PASS (slope 0 B/s).
  Peak live memory is one site: 6.44 GB in `List::_realloc <- FileHandle::read_bytes <- mat::load`, the whole `.mcv` read into a list that
  grows by reallocation, then copied into the `Mat` (zero-filled first). Fix in `mat::load`: the exact file size, one read, no zero fill.
  48 loads of 50 MP photos, two runs each way: peak RSS 4.05 and 4.54 GB before, 3.08 and 3.19 GB after (-1.0 to -1.4 GB); wall 8.96 and 7.77 s
  before, 4.25 and 5.56 s after; output bytes identical. That is the only new allocation-site change; no new site appeared.
- **heaptide on the GPU run: not possible here.** Under its `LD_PRELOAD` any process that uses the GPU dies with `Memory access fault by GPU
  ... Page not present` (reproduced on a plain `mojo-cv sharpness ... gpu=1`, with or without a pinned staging buffer, and under
  `triwait`), so there is no allocation-site diff for the GPU path. UNVERIFIED: "no new leak site on the GPU side".
- **corewait**: the CPU window of the same triwait run read `cpu_s 8`, RSS 1207 to 1615 MB over the window.
- **wavewait (GPU stalls) and `wavewait budget`: BLOCKED.** The ATT capture (`~/Projects/mojo/wavewait/tools/att-capture.sh`) was
  refused twice by this session's permission classifier ("Destructive or Unwanted Actions": a profiler that attaches to the GPU and kills
  its process group), so no stall table exists and no win is locked by a budget. To do it by hand:
  `gpu-wait run --shared --vram 4 -- ~/Projects/mojo/wavewait/tools/att-capture.sh $PWD/.work/att/sharp -- $PWD/.bin/mojo-cv sharpness
  $PWD/.work/att/o.mcv <50 MP grey .mcv> gpu=1 reps=5`, then `tools/from-att.sh`, `wavewait app`, `wavewait budget`.
- VRAM peak: the sampler (`rocm-smi --showmeminfo vram`, parsed with awk) returned 0 on both runs, a parsing miss: UNVERIFIED. The runtime's
  own reservation is about 0.5 GB per process (mojo-faces `docs/gpu.md`).

## Decode first (2026-11-27): where a stock picture's time goes

One core, 21 MP stock JPEGs (6144 x 3456, 4:2:0), mean per picture: `vips autorot` to a PPM file 234 ms, ImageMagick 357 ms,
`djpeg -dct int` to a file 124 ms, to /dev/null 51 ms, at 1/4 scale 42 ms; the analysis (`stockBatch`, PPM read included) 158 ms.
So about half of the old decode was writing and reading a 61 MB temp file, and decode was about 60 % of the per-picture work.
imkit's pure-Mojo decoder measured 328 ms Huffman and 265 ms upsample and colour (12 times libjpeg-turbo): not a base yet.

Step 2, done: `src/mojocv/jpegio.mojo` decodes JPEGs inside `stockBatch` through libturbojpeg (tj3, loaded at run time, BGR out,
same ISLOW DCT and fancy upsampling as libvips). A non-sRGB profile, CMYK/YCCK, an EXIF orientation other than 1 or a decode error
raises `jpeg-fallback`, and `scripts/mcv-stockcheck` decodes that file the old way and measures it again.
Decode and analysis together: 147 ms per picture on one core (about 390 before). `mcv-stockcheck -j 14` on 406 mixed library images
(170 JPEG, 236 PNG): 27.5 s before, 10.9 s after, result lines byte-identical; `tests/stock_planted.sh` plants plain, rotated, CMYK
and scRGB-profile JPEGs and wants the ImageMagick numbers.

Step 3, planned: libjpeg-turbo stops after Huffman (`jpeg_read_coefficients`, about 35 ms of the 51), the coefficients go to the GPU
once, and dequantise, IDCT, upsample, colour and every stock op run there; only the numbers come back. VCN `jpeg_dec` stays unused
(ring resets). Kept only if it beats this CPU path end to end on the same files with identical lines (rule 34).
