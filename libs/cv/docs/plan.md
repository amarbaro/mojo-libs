# Plan: mojo-cv, a clean-room solidcv equivalent on the 7900 XTX

## Context
Mario asked for full parity with solidcv (Rust, ~23.7k LOC, ~280 pub fns, Apple/NVIDIA-only kernels, paid cloud,
encrypted "vault" modules). Done so far from it: `blockdiff` (= prune_vlm_patch_tokens) and the 1-bit ask
prefilter (= SaeBinaryCircuitMatcher). This plan covers the rest.

Rules that shape it:
- **Clean room** (skill clean-room-build): idea only, never code. I (Claude, this session) read solidcv; I write
  one provenance note per track from it plus primary sources. Lanes never open `.work/solidcv-zip` or the
  decoded vault. `clean-room-check OURS REF` must PASS before any merge.
- **Mojo**, Python only as oracle (`tools/`, cv2 5.0.0 in `~/iTools/video/camera-motion/v`).
- **Beat the original, measured**: the real competitor on this machine is OpenCV 5.0 on the 7800X3D. Per hot op:
  output within tolerance of cv2 and time <= cv2 on 1080p, CPU or GPU, whichever measures faster (blockdiff
  lesson: memory-bound ops go to CPU).
- XL+: runs as herdr lanes (lane-dispatch `lanes.sh`, `sonnet[1m]`, effort high, one worktree per track), boss
  (this session) re-runs gates and commits. Fan-out 5.

## Repo
`~/Projects/mojo/mojo-cv/`: `src/` (one package), `tools/oracle_cv2.py` + `tests/cases/*.txt` (one differential
harness, mojo-lean step 5), `docs/provenance/<track>.md`, `bench/`. Image I/O via ffmpeg raw pipes (no codecs
written). Reuse: blockdiff's frame reader, newera `lib/` (vq2lib, prunelib), mojo-baro kernels for any GEMM.

## Phase 0 (me, before lanes): M
Scaffold repo, `Mat` (owned buffer, rows/cols/channels/dtype, ROI views, zero-copy), raw I/O, oracle harness
(`cases.txt` row = op + args + input; compares arrays with per-op tolerance, prints FAIL op/maxdiff), bench
runner (cv2 vs ours, 1080p, 5 rounds). Provenance notes for tracks A to F. Lane briefs.

## Tracks (lanes, parallel after phase 0)
| Lane | Scope (solidcv module) | Oracle | Size |
|---|---|---|---|
| A imgproc | core ops (absdiff, xor/and, flip, rotate, transpose, convert), cvtColor, resize (incl. Lanczos), warpAffine, remap, pyrDown, gaussianBlur, threshold, Sobel, integral, morphology, connectedComponentsWithStats, Canny, findContours, goodFeaturesToTrack, grabCut, drawing, HOG detectMultiScale, blobFromImage | cv2 | L |
| B features+video | ORB detect/compute, BFMatcher Hamming, knn ratio test, cornerSubPix, calcOpticalFlowPyrLK, Farneback | cv2 | L |
| C calib3d | estimateAffine2D, Rodrigues, projectPoints, undistortPoints (+fisheye), solvePnP, solvePnPRansac (EPnP + SO(3) Gauss-Newton refine), findEssentialMat, recoverPose, stereoRectify, initUndistortRectifyMap, StereoSGBM, findChessboardCorners, ArUco 4x4 detect | cv2 | XL |
| D 3D/time | voxelize / unvoxelize point clouds, Zobrist octree hash + O(log N) diff, sim3 alignment (Umeyama), 3D wavelet static-memory compression, binary 3D descriptors, TAPVid-3D metrics, static-vs-moving separation, burst super-resolution, phase correlation | brute-force Mojo oracle + published metric defs | L |
| E cad/cae | B-spline/NURBS fit + eval, voxel boundary to watertight mesh (Euler check), GLB writer, STEP AP242 writer, stress tensor: von Mises, principal values, colormap | gltf-validator / round-trip read, closed-form cases | L |

LOC estimate after mojo-lean 1-3 (import std/max.gpu, one generic body per op family): A 1500, B 800, C 2000,
D 1200, E 1200: about 6.7k Mojo.

## Out (cannot exist or be checked locally)
`cloud_ws`, `solidcv_fx` (paid solidsf API), `m31_vision` dispatch, `h3_av` (video-generation planning over their
servers), `hardware.rs` (Metal/NEON/PTX: replaced by our CPU/GPU paths). Say so if wanted: they would be a
client for a service we do not have.

## Gates per lane
- Own cases green vs oracle (tolerance per op stated in the case row), full harness green, captured to
  `.work/<lane>-gate.txt`.
- Bench row per hot op: ours vs cv2 time on 1080p; a slower op is reported, not hidden.
- GPU runs via `gpu-wait run --shared --vram 1` for parity, exclusive only for timing.
- `clean-room-check src/ ~/Projects/AMD/.work/solidcv-zip/solidcv-main/src` PASS (boss runs it).
- Three repairs then `.work/<lane>-failure.md`; report `exchange/lane-<X>-report.md`; DONE pushed.

## Verification (§18)
- Harness: every case row passes against cv2 / brute oracle; mutant-check on 3 ops proves the gate bites.
- User-level: `mojo-cv` CLI runs a real pipeline on a real video: ORB + LK track across 100 frames of
  `~/Videos/obs.space/...mkv`, PnP on a printed chessboard photo, GLB of a voxelized clip opened in Blender.
- Bench table in `docs/bench.md`: per op cv2 time, ours, winner device.

## Order
Phase 0 (me) -> lanes A B C D E in parallel -> boss merges in order A, B, C, D, E (later ones depend on Mat
and imgproc) -> verification pipeline -> Brain note + release-note tag.

## Lane items (2 Sonnet lanes, 2026-10-22)

Shared rules for both items:
- **Clean room**: read `docs/provenance/<your note>.md` and the primary sources it names. Never open
  `~/Projects/AMD/.work/solidcv-zip`, `~/Projects/AMD/.work/solidcv-vault`, or search the web for solidcv code.
- Mojo only in `src/`; Python only in `tools/` as an oracle (cv2 5.0 + numpy:
  `~/iTools/video/camera-motion/v/bin/python`). Base: `src/mojocv/mat.mojo` (Mat, load/save) and `tools/mcv.py`.
  Build with `.venv/bin/mojo` (`-I src`).
- One harness, not a test per function: `tests/cases/<module>.txt` rows run through `tests/run.sh`, which
  runs ours and the oracle on the same `.mcv` inputs and compares with the tolerance written in the row.
  Lane L2D creates `tests/run.sh` and the CLI `src/main.mojo` (`mojo-cv OP OUT IN... [k=v]`); lane L3D adds
  its own ops to the same CLI file in a separate dispatch function `src/mojocv/cli3d.mojo` to avoid conflicts.
- Speed rows in `docs/bench.md` (ours vs cv2, 1920x1080, best of 5) for every hot op. GPU only through
  `gpu-wait run --shared --vram 1 --timeout S` (stdin is not forwarded: redirect inside `sh -c`).
- Commit each passing module. Gate output to `.work/<item>-gate.txt`. Report to `exchange/lane-<item>-report.md`.

### L2D: 2D vision (provenance: docs/provenance/2d.md)
Files: `src/main.mojo`, `src/mojocv/{core,imgproc,features,video,calib3d}.mojo`, `tools/oracle_cv2.py`,
`tests/run.sh`, `tests/cases/*.txt`, `tests/fixtures/` (generated by a script, real screenshots allowed:
`~/Projects/AMD/.work/shotA.png`, `shotB.png`), `docs/bench.md`.
Order: (1) harness + CLI + core ops (absdiff, bitwise, flip, rotate, transpose, convert) proven on 3 ops;
(2) imgproc: cvtColor, resize (nearest, linear, cubic, Lanczos4), warpAffine, remap, pyrDown, GaussianBlur,
threshold, Sobel, integral, erode/dilate, connectedComponentsWithStats, Canny, findContours,
goodFeaturesToTrack, grabCut, line/rectangle drawing, HOG detectMultiScale (people detector), blobFromImage;
(3) features + video: ORB, BFMatcher Hamming, knn ratio test, cornerSubPix, calcOpticalFlowPyrLK, Farneback;
(4) calib3d: estimateAffine2D, Rodrigues, projectPoints, undistortPoints (+fisheye), solvePnP,
solvePnPRansac, findEssentialMat, recoverPose, stereoRectify, initUndistortRectifyMap, StereoSGBM,
findChessboardCorners, ArUco 4x4 detection.
Floor: every op listed has at least 2 case rows (one real image, one edge case) passing.

### L3D: 3D / time and CAD / CAE (provenance: docs/provenance/3d.md)
Files: `src/mojocv/{voxel,octree,align,wavelet,desc3d,tapvid,phasecorr,burst,nurbs,mesh,glb,step,cae}.mojo`,
`src/mojocv/cli3d.mojo`, `tests/cases3d/*.txt`, `tests/run3d.sh`, `tools/` oracles if numpy suffices.
Order: voxel + octree (Zobrist) + diff + static/moving; Umeyama; Haar 3D; binary descriptors; TAPVid-3D
metrics; phase correlation; burst SR; NURBS fit/eval; voxel boundary to watertight mesh; GLB writer +
reader; STEP AP242 writer + reader; CAE (von Mises, principal values, colormap).
Floor: each module has a brute-force or closed-form check passing; octree diff node-count number printed.
