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
picture and the CPU's vector code beats them. So `stockPhoto gpu=1` (photos of 4 MP or more, `gpumin=`) sends only the shrink and the
sharpness to the GPU and keeps grey on the CPU. The per-photo gain is the 10 to 20 ms of those two ops, small against the decode that
dominates the stock job: 3.0 s per 50 MP iPhone JPEG on the CPU (4 photos in 12.2 s, the ImageMagick path of a photo with an ICC
profile; the VCN `jpeg_dec` ring is not used, it reset three times on these files). The GPU path pays for the shrink of a big
batch, not for 1024 px photos, which stay on the CPU.
