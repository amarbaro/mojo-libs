#!/usr/bin/env bash
# Build the row-driver binaries into build/<row file stem> (one driver serves the four detection row files).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build .work
J=${MOJO_JSON:-/home/mario/Projects/mojo/mojo-json/src}
mojo build -O3 -I src -I "$J" tests/rows_detection.mojo -o build/detection_rows 2>.work/s1-build.log || { tail -40 .work/s1-build.log; echo "FAIL build: see .work/s1-build.log"; exit 1; }
for s in detection_converters detection_detections detection_iou detection_nms s1_detections s1_utils; do cp build/detection_rows "build/$s"; done
