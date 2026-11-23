#!/usr/bin/env bash
# CI entry point, same on a GitHub runner and a local Ubuntu VM: install, build, then every CPU gate.
# Both packages: src/mojocv (cv2/numpy rows) and src/supervision (Python supervision rows). The speed table (docs/bench.md) and the real-photo rows (tests/cases/real.txt) are run by hand, see README.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
uv sync || { echo "FAIL setup: uv sync"; exit 1; }
python3 -c 'import platform; print("oracle python", platform.python_version())'
# cv2 5.0 has no HOGDescriptor: the HOG rows take their oracle from cv2 4.8.1 in a second environment.
if [ ! -x .venv4/bin/python ]; then
  { uv venv --python 3.11 .venv4 && uv pip install --python .venv4/bin/python opencv-python-headless==4.8.1.78 "numpy<2"; } >/dev/null 2>&1 \
    || { echo "FAIL setup: cv2 4.8.1 environment (.venv4) for the HOG rows"; exit 1; }
fi
mkdir -p .work .bin
"${MOJO:-.venv/bin/mojo}" build -I src examples/quickstart.mojo -o .work/quickstart 2>.work/build.err \
  || { echo "FAIL build: examples/quickstart.mojo"; grep error .work/build.err | head -20; exit 1; }
.work/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
# fs-gpu2 and fs-stream (R3, R4): their oracle is tests/cases_gpu/fs_suite.py (oracle_cv2 has no stream op) and their fixtures
# come from its prep. CI runs the CPU arm with the GPU hidden; tests/run_gpu.sh fs2 runs the GPU arm.
fs=(.venv/bin/python -I tests/cases_gpu/fs_suite.py)
{ "${fs[@]}" prep && HIP_VISIBLE_DEVICES=-1 ROCR_VISIBLE_DEVICES=-1 "${fs[@]}" rows --no-arm tests/cases/fs-gpu2.txt tests/cases/fs-stream.txt; } > .work/fs2-cpu.log 2>&1 \
  || { grep -v '^PASS' .work/fs2-cpu.log | tail -8; echo "FAIL fs2 cpu: tests/cases_gpu/fs_suite.py"; exit 1; }
echo "ok fs2 cpu: $(grep -c '^PASS' .work/fs2-cpu.log) rows"
cases=()
for f in tests/cases/*.txt; do
  case ${f##*/} in fs-stream.txt) continue;; real.txt) [ -f tests/real/frame0.mcv ] || continue;; esac
  cases+=("$f")
done
tests/run.sh "${cases[@]}" || { echo "FAIL 2d: tests/run.sh"; exit 1; }
.venv/bin/python -I tools/fastpath_check.py > .work/fastpath.log || { echo "FAIL fastpath: tools/fastpath_check.py"; tail -5 .work/fastpath.log; exit 1; }
tests/run3d.sh || { echo "FAIL 3d: tests/run3d.sh"; exit 1; }
.venv/bin/python -I tools/malformed_check.py > .work/malformed.log || { echo "FAIL malformed: tools/malformed_check.py"; grep BAD .work/malformed.log | head -5; exit 1; }
"${MOJO:-.venv/bin/mojo}" run -I src tests/ransac_iters.mojo > .work/ransac.log 2>&1 || { echo "FAIL ransac_iters: tests/ransac_iters.mojo"; tail -2 .work/ransac.log; exit 1; }
.venv/bin/python -I tools/stereo_check.py > .work/stereo.log || { echo "FAIL stereo: tools/stereo_check.py"; grep BAD .work/stereo.log | head -5; exit 1; }
# supervision package (src/supervision): the row harness self-test, every row driver, then every row file against the
# Python supervision / cv2 oracle. Needs mojo-json and mojo-gzip sources: MOJO_JSON/MOJO_GZIP, else a sibling checkout,
# else a shallow clone into .work/deps.
export PATH="$PWD/.venv/bin:$PATH"   # tests/supervision/build*.sh call a bare `mojo`
dep() {  # dep VAR LIB: export VAR = LIB's src directory
  local var=$1 lib=$2 d
  [ -z "${!var:-}" ] || return 0
  d="../$lib"; [ -d "$d/src" ] || { echo "FAIL setup: $d/src missing (sibling library in the monorepo)"; exit 1; }
  export "$var=$PWD/$d/src"
}
dep MOJO_JSON json; dep MOJO_GZIP gzip
export ORACLE_PY=${ORACLE_PY:-$PWD/.venv/bin/python}   # the pixel rows read PNGs with opencv and numpy
mkdir -p build
m=3; ok=0
gate() { local name=$1; shift; if "$@"; then ok=$((ok+1)); echo "ok $name"; else echo "FAIL supervision $name"; echo "FAIL supervision $((m-ok))/$m"; exit 1; fi; }
gate selftest tests/supervision/selftest.sh
gate build tests/supervision/build_all.sh
gate rows tests/supervision/run.sh
echo "PASS supervision $ok/$m"
echo "PASS ci"
