# Lane L2D: 2D vision, features, video, calib3d (current truth)

Mojo ports of the OpenCV 5.0 ops listed in `docs/plan.md` (L2D), each checked against cv2 5.0 on the same `.mcv`
inputs by one harness. Sources: OpenCV 5.0 documentation and the papers in `docs/provenance/2d.md`; nobody on the lane
read solidcv.

## Run it

```
tests/run.sh                      # build .bin/mojo-cv, make fixtures, run every row of tests/cases/*.txt
tests/run.sh tests/cases/imgproc.txt
tests/run.sh --bench-all --md docs/bench.md   # speed rows (docs/bench.md)
```

CLI: `mojo-cv OP OUT IN... [k=v]`. Arrays are `.mcv` (`src/mojocv/mat.mojo`, `tools/mcv.py`). Several outputs go to
`OUT`, `OUT.1`, `OUT.2`, ... `reps=N` repeats the compute and prints `TIME best_ms`. Ops that are not 2D fall through to
`dispatch3d` (lane L3D), so one binary serves both.

Case row: `id op IN... [k=v...] => cmp[, cmp...]`, one comparison per output file: `exact`, `max:T`, `mean:T`,
`frac:T:F` (share of values within T), `iou:F`, `pts:T:F` (share of cv2's points with one of ours within T px),
`cnt:R`, `orb:T:F:H` (keypoints matched within T px and mean descriptor Hamming distance). The tolerance is in the row.

## Op map (module, args, what is compared)

| module | ops |
|---|---|
| `core` | flip code, rotate code, transpose, absdiff, bitwise_and/or/xor/not, convert to alpha beta (all five dtypes) |
| `imgproc` | cvtColor code=bgr2gray rgb2gray gray2bgr bgr2rgb bgr2hsv hsv2bgr bgr2ycrcb ycrcb2bgr; resize w h interp=0..3 (nearest, linear, cubic, Lanczos4); warpAffine M interp border inv; remap; pyrDown; GaussianBlur ksize sigma; threshold (binary, inv, trunc, tozero, tozero_inv, Otsu); Sobel/Scharr; integral; erode/dilate (rect, cross, ellipse); connectedComponentsWithStats; Canny; findContours (external, list; none, simple); goodFeaturesToTrack; grabCut; line; rectangle; HOGScores; detectMultiScale; groupRectangles; blobFromImage |
| `features` | ORB; bfmatch (Hamming best match); knnmatch (2-NN + ratio test) |
| `video` | cornerSubPix; calcOpticalFlowPyrLK; calcOpticalFlowFarneback |
| `calib3d` | Rodrigues; projectPoints; undistortPoints; initUndistortRectifyMap (+ `fisheye_` for the three); estimateAffine2D; solvePnP; solvePnPRansac; findEssentialMat; recoverPose; stereoRectify; StereoSGBM; findChessboardCorners; aruco_detect (4x4_50) |

Exactness (cv2 5.0 rows): bit exact are the core ops, pyrDown, Sobel, threshold, integral, erode/dilate, cvtColor
(gray, hsv), nearest resize/remap/warp, connectedComponents, Canny, findContours, line/rectangle, descriptor matching,
ArUco ids; within 1 grey level are resize, warp, remap, blob, YCrCb, HSV to BGR; float64 geometry agrees to 1e-9.

## Where we differ from cv2 (stated, measured)

- **HOG**: cv2 5.0 has no `HOGDescriptor`. The HOG rows run the oracle under cv2 4.8.1 (the vpython cache interpreter,
  `MCV_PY4`) and take the people-detector weights from it. Window scores agree to 2e-3, boxes to 2 px.
- **Gray weights**: cv2 5.0 computes 8-bit gray with 15-bit weights (3735, 19235, 9798), not the older 14-bit ones; fitted
  on all 16.7M colours.
- **Warps and remaps** interpolate at the exact float position in cv2 5.0 (no 1/32 tables); so do we.
- **findEssentialMat** draws eight-point models (MSAC cost) where cv2 draws five-point sets; on consistent data both give
  the same E. E is returned with unit Frobenius norm and the largest entry positive (cv2's is normalised the same way
  by the oracle). Noisy data agree only loosely (row `ess_noisy`).
- **solvePnP**: homography (coplanar) or 3x4 DLT start, then Levenberg-Marquardt on the pixel error with distortion.
  No EPnP. RANSAC samples 6 points (4 coplanar), 100 iterations, adaptive.
- **stereoRectify**: default alpha (-1) and horizontal baseline only; cv2 5.0 averages the two focal lengths.
- **StereoSGBM**: own SGM (Birchfield-Tomasi cost, box window, eight paths, parabola refinement, left-right and
  uniqueness checks), not cv2's pre-filtered 5-path pipeline: 94 to 95 percent of pixels agree within one disparity.
- **findChessboardCorners**: set of corners matches; order is "cols axis right, rows axis down", cv2 sometimes starts
  from the other end. cv2's refinement jitters 0.4 px on axis-aligned boards.
- **grabCut**: Dinic min-cut and k-means++ seeding; masks agree (IoU 1.0 on both rows) but are not bit identical.
- **ORB**: the 256 rBRIEF pairs are recovered from cv2 by single-pixel probing (unique solution per bit) and listed as data
  in `features.mojo`. 98.6 percent of cv2's keypoints on a 1080p screenshot are matched within 1 px, mean 0.3 bit apart.
- **ArUco**: the 50 words of 4x4_50 were read from cv2's rendered markers.

## Not implemented

cvtColor Lab/Luv/YUV, resize INTER_AREA, threshold triangle, Harris in goodFeaturesToTrack, findContours hierarchy
(tree/ccomp), thick lines (> 1 px) and thick rectangles, anisotropic or even erode kernels, vertical stereo rectify,
stereoRectify alpha in [0, 1], GPU kernels (every op is CPU; `gpu-wait` was not needed).

## Speed

`docs/bench.md`. Dispatch lesson worth keeping: `max.algorithm.parallelize` with 16 workers costs ~215 us per region,
with 8 (the physical cores) ~8 us. Mojo 1.2 nightly notes: bare `[...]` is an `Array`, closures are `def f(i: Int) {imm}`,
a `Mat` that only a raw pointer outlives is freed at its last named use (`_ = m.rows` keeps it).
