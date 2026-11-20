#!/usr/bin/env bash
# Build the S4 row drivers to build/<row file stem> (the tests/supervision/run.sh convention). Usage: scripts/supervision/build_tools.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
MOJO=${MOJO:-mojo}
JSON_SRC=${JSON_SRC:-$PWD/../json/src}
mkdir -p build
for stem in slicer slicer_merge line sinks smoother zone; do
  "$MOJO" build -O1 -I src -I tools/supervision/drivers -I "$JSON_SRC" "tools/supervision/drivers/tools_$stem.mojo" -o "build/tools_$stem" \
    2> ".work/build-tools_$stem.log" || { tail -20 ".work/build-tools_$stem.log"; echo "FAIL build tools_$stem: see .work/build-tools_$stem.log"; exit 1; }
done
