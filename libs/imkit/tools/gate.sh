#!/usr/bin/env bash
# The package's gate: precompile, build every test on the CPU, then run them. ui_test runs compose on the GPU (under
# gpu-wait); window_test opens a window for about 2 s (needs a Wayland or X display).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
./.venv/bin/mojo precompile src/imkit -o .work/imkit.mojoc || { echo "FAIL precompile: src/imkit"; exit 1; }
for t in font_test ui_test window_test; do
  ./.venv/bin/mojo build -I src "tests/$t.mojo" -o ".work/$t" > ".work/$t.build.log" 2>&1 || { echo "FAIL build $t: .work/$t.build.log"; exit 1; }
done
.work/font_test
gpu-wait run --priority 90 --vram 1 --timeout 300 -- .work/ui_test
.work/window_test
echo "PASS gate: precompile, font_test, ui_test, window_test"
