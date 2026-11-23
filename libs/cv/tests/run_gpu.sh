#!/usr/bin/env bash
# tests/run_gpu.sh: the GPU ops of src/mojocv/gpu.mojo against the same oracle as their CPU twins. The rows of tests/cases_gpu/gpu.txt
# (the CPU rows with gpu=1: cv2 5.0 / numpy, same tolerance) run inside one gpu-wait job; then crop is checked on the GPU and the CPU
# against a numpy slice, and a run with the GPU hidden must still write the CPU answer (the fallback).
set -euo pipefail
cd "$(dirname "$0")/.."
# gw LABEL CMD...: one gpu-wait job (shared, small VRAM), or the command itself when the caller already is a GPU job (tests/gpu_all.sh)
gw() { local l=$1; shift; if [ -n "${CV_IN_GPU_JOB:-}" ]; then "$@"; else gpu-wait run --shared --vram 4 --mem 8 --timeout 1800 --label "$l" -- "$@"; fi; }
[ -x .bin/mojo-cv ] || { echo "FAIL setup: .bin/mojo-cv missing"; exit 1; }
mkdir -p .work/gpurows
gw cv-gpu-rows tests/run.sh tests/cases_gpu/gpu.txt > .work/gpurows/rows.log 2>&1 \
  || { tail -8 .work/gpurows/rows.log; echo "FAIL gpu rows: tests/cases_gpu/gpu.txt"; exit 1; }
tail -1 .work/gpurows/rows.log
fx=tests/fixtures/hd.mcv
.bin/mojo-cv crop .work/gpurows/crop_cpu.mcv $fx x=101 y=51 w=333 h=222 > /dev/null
gw cv-gpu-crop .bin/mojo-cv crop .work/gpurows/crop_gpu.mcv $fx x=101 y=51 w=333 h=222 gpu=1 > .work/gpurows/crop.log 2>&1
cmp .work/gpurows/crop_cpu.mcv .work/gpurows/crop_gpu.mcv || { echo "FAIL crop: GPU and CPU differ"; exit 1; }
.venv/bin/python -I - <<'EOF'
import sys, numpy as np
sys.path.insert(0, "tools")
import mcv
a = mcv.load(sys.argv[1] if len(sys.argv) > 1 else "tests/fixtures/hd.mcv")
b = mcv.load(".work/gpurows/crop_gpu.mcv")
assert (a[51:51 + 222, 101:101 + 333] == b.reshape(222, 333, -1).squeeze() if a.ndim == 3 else a[51:51 + 222, 101:101 + 333] == b).all(), "crop differs from the numpy slice"
print("PASS crop: GPU == CPU == numpy slice")
EOF
# no accelerator visible: the same command must still write the CPU answer
HIP_VISIBLE_DEVICES=-1 ROCR_VISIBLE_DEVICES=-1 .bin/mojo-cv Sobel .work/gpurows/sob_hidden.mcv tests/fixtures/hdg.mcv dx=1 dy=0 ksize=3 gpu=1 > .work/gpurows/hidden.log 2>&1
.bin/mojo-cv Sobel .work/gpurows/sob_cpu.mcv tests/fixtures/hdg.mcv dx=1 dy=0 ksize=3 > /dev/null
cmp .work/gpurows/sob_hidden.mcv .work/gpurows/sob_cpu.mcv || { echo "FAIL fallback: GPU hidden gives another answer"; exit 1; }
echo "PASS fallback: GPU hidden ($(tail -1 .work/gpurows/hidden.log | cut -c1-40)) writes the CPU answer"
echo "PASS run_gpu"
