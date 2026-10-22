# mojo-cv

Clean-room computer vision in Mojo for the 7900 XTX and 7800X3D: OpenCV-style 2D ops, calibration, 3D/time geometry and CAD export, each checked against an oracle (cv2 5.0, brute force or closed form) and timed against cv2. Plan: `docs/plan.md`. Ideas and sources per track: `docs/provenance/`.

Images and arrays travel as `.mcv` files (`src/mojocv/mat.mojo`, `tools/mcv.py`). 2D vision, features, video and calib3d: `docs/l2d.md`, speed rows `docs/bench.md`.
