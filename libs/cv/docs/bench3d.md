# L3D speed rows

Measured 2026-10-22 on the 7800X3D (CPU only, 16 threads where an op is threaded; no GPU was used).
Ours: `.bin/mojo-cv3d OP ... reps=5`, best of 5, compute step only (files already loaded). Baseline: best of 5 Python
calls on in-memory arrays. Command: `python tools/bench3d.py`.

| op | size | ours (ms) | baseline | baseline (ms) | ours / baseline | note |
|---|---|---|---|---|---|---|
| phasecorr | 1920x1080 f64 | 39.81 | cv2.phaseCorrelate | 60.61 | 0.657 | CPU, 16 threads; cv2 returns (-21.0, 13.0) as well, ours is exact on fractional shifts too |
| burst (4 frames, splat only) | 4 x 1920x1080 f64 -> 3840x2160 | 110 | cv2.resize 2x INTER_LINEAR (1 frame) | 2.282 | 48.2 | no cv2 burst op; resize is the cost of the single-frame alternative |
| odiff, 1 changed cell | 64^3 scene, 3000 cells | 0.00315 | cv2.absdiff + countNonZero (dense, grids prebuilt) | 0.01271 | 0.248 | walk of two prebuilt trees, 35 of 262144 cells visited |
| octree build | 64^3 scene, 3000 cells | 0.2106 | numpy: dense grid fill | 0.01842 | 11.4 | the tree is built once per frame; the diff then costs the change |
| haar3c | 128^3 f64 | 72.46 | numpy oracle (python loops over levels) | 155.1 | 0.467 | no cv2 equivalent |
| describe | 3000 points, k=16 | 69.28 | - | - | - | O(N^2) kNN; no cv2 equivalent |
| match (Hamming, 64 bit) | 10000 x 10000 | 14.51 | cv2.BFMatcher(NORM_HAMMING).match | 77.18 | 0.188 |  |
| mesh | 17177 cells in 40^3 | 108 | - | - | - | no cv2 equivalent |
| nurbs_eval | 512x512 samples, 16x16 net | 110.8 | numpy oracle | 1748 | 0.0634 |  |
| nurbs_fit | 200x200 samples -> 16x16 net | 1.658 | numpy oracle (lstsq) | 2.997 | 0.553 |  |
| umeyama | 100000 points | 2.133 | numpy oracle (SVD) | 4.852 | 0.44 |  |
