#!/usr/bin/env bash
# tests/run_gpu.sh: the GPU ops of src/mojocv/gpu.mojo against the same oracle as their CPU twins. The rows of tests/cases_gpu/gpu.txt
# (the CPU rows with gpu=1: cv2 5.0 / numpy, same tolerance) run inside one gpu-wait job; then crop is checked on the GPU and the CPU
# against a numpy slice, and a run with the GPU hidden must still write the CPU answer (the fallback).
set -euo pipefail
cd "$(dirname "$0")/.."
# gw LABEL CMD...: one gpu-wait job (shared, small VRAM; GPU_WAIT_ARGS replaces the flags), or the command itself when the caller already is a GPU job (tests/gpu_all.sh)
gw() { local l=$1; shift; if [ -n "${CV_IN_GPU_JOB:-}" ]; then "$@"; else gpu-wait run ${GPU_WAIT_ARGS:---shared --vram 4 --mem 8 --timeout 1800} --label "$l" -- "$@"; fi; }
[ -x .bin/mojo-cv ] || { echo "FAIL setup: .bin/mojo-cv missing"; exit 1; }
if [ "${1:-}" = fs2 ]; then  # tests/run_gpu.sh fs2: the full-stack P1 rows (R3a absdiff, R3b resize, R4 stream), see tests/cases_gpu/fs_suite.py
  FS_H2=${FS_H2:-tests/fixtures/fs-h2}; export FS_H2
  PYS=(.venv/bin/python -I tests/cases_gpu/fs_suite.py)
  if [ -n "$(find src -newer .bin/mojo-cv -name '*.mojo' | head -1)" ]; then
    .venv/bin/mojo build -O3 -I src src/main.mojo -o .bin/mojo-cv 2>.work/build.log || { tail -30 .work/build.log; echo "FAIL build: see .work/build.log"; exit 1; }
  fi
  mkdir -p .work/fs2mut
  rc=0; "${PYS[@]}" prep || rc=$?; [ $rc = 0 ] || exit $rc
  # the arm proof and the rows: a gpu=1 row without a GPU-ARM line fails; fb_ rows (an uncovered parameter) must show the CPU answer
  gw cv-fs2-rows env FS_H2="$FS_H2" "${PYS[@]}" h2 > .work/fs2mut/h2.log 2>&1 || { tail -12 .work/fs2mut/h2.log; echo "FAIL fs2 h2: tile masks or the absdiff twin differ from the fs-h2 references"; exit 1; }
  grep -c '^PASS h2' .work/fs2mut/h2.log | sed 's/^/PASS fs2 h2 reference lines: /'
  gw cv-fs2-rows env FS_H2="$FS_H2" "${PYS[@]}" rows tests/cases/fs-gpu2.txt tests/cases/fs-stream.txt > .work/fs2mut/rows.log 2>&1 || { grep -v '^PASS' .work/fs2mut/rows.log | tail -12; echo "FAIL fs2 rows"; exit 1; }
  grep -c '^PASS .*arm=GPU' .work/fs2mut/rows.log | sed 's/^/PASS fs2 rows that ran the GPU arm: /'
  tail -1 .work/fs2mut/rows.log | sed 's/^/PASS fs2 /'
  # no accelerator visible: the same rows still pass on the CPU path and none claims a GPU line
  HIP_VISIBLE_DEVICES=-1 ROCR_VISIBLE_DEVICES=-1 "${PYS[@]}" rows --no-arm tests/cases/fs-gpu2.txt > .work/fs2mut/hidden.log 2>&1 || { grep -v '^PASS' .work/fs2mut/hidden.log | tail -8; echo "FAIL fs2 hidden GPU: rows differ without an accelerator"; exit 1; }
  grep -c '^PASS' .work/fs2mut/hidden.log | sed 's/^/PASS fs2 rows with the GPU hidden (CPU answer, no GPU line): /'
  # the same rows through the cv2 oracle driver (tests/run.sh): the CPU-comparable ops of fs-gpu2
  gw cv-fs2-cv2 tests/run.sh tests/cases/fs-gpu2.txt > .work/fs2mut/run-sh.log 2>&1 || { tail -8 .work/fs2mut/run-sh.log; echo "FAIL fs2 run.sh rows"; exit 1; }
  tail -1 .work/fs2mut/run-sh.log | sed 's/^/PASS fs2 run.sh: /'
  # planted failures: each mutant is built from mutated source, builds, runs, and fails a row; a mutant that survives fails the gate
  n=0
  while IFS=$'\t' read -r mf old new cases; do
    [ "$mf" = file ] && continue
    n=$((n + 1)); d=.work/fs2mut/m$n; rm -rf "$d"; mkdir -p "$d"; cp -r src "$d/src"
    python3 -I - "$d/$mf" "$old" "$new" <<'PY' || { echo "FAIL mutant $n: pattern not found exactly once in $mf"; exit 1; }
import sys
p, old, new = sys.argv[1:4]
t = open(p).read()
assert t.count(old) == 1, t.count(old)
open(p, "w").write(t.replace(old, new))
PY
    .venv/bin/mojo build -O3 -I "$d/src" "$d/src/main.mojo" -o "$d/mojo-cv" 2> "$d/build.log" < /dev/null || { tail -5 "$d/build.log"; echo "FAIL mutant $n: does not build"; exit 1; }
    if gw cv-fs2-mut env FS_H2="$FS_H2" MCV_BIN="$PWD/$d/mojo-cv" "${PYS[@]}" rows "$cases" > "$d/rows.log" 2>&1 < /dev/null; then
      echo "FAIL mutant $n survived: every row of $cases passed with '$new' in $mf"; exit 1
    fi
    k=$(grep -c '^FAIL' "$d/rows.log" || true)
    [ "$k" -ge 1 ] || { tail -5 "$d/rows.log"; echo "FAIL mutant $n: the run failed without a failed row (harness fault, not a kill)"; exit 1; }
    echo "PASS mutant $n killed by $k row(s), first: $(grep -m1 '^FAIL' "$d/rows.log" | cut -c1-110)"
  done < tests/cases_gpu/fs_mutants.tsv
  echo "PASS run_gpu fs2"
  exit 0
fi
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
