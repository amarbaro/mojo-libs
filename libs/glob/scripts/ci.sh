#!/usr/bin/env bash
# CI entry point (GitHub runner or local): install, build, then every gate. MOJO=path overrides the toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${MOJO:-}" ]; then
  command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
  uv sync -q || { echo "FAIL setup: uv sync"; exit 1; }
  MOJO=.venv/bin/mojo
fi
"$MOJO" --version
mkdir -p .work/t
for t in tests/cases:.work/cases tests/api:.work/t/api examples/quickstart:.work/t/quickstart; do
  "$MOJO" build -O3 -I src ${MOJO_FLAGS:-} "${t%%:*}.mojo" -o "${t##*:}" 2>.work/build.err || { echo "FAIL build: ${t%%:*}.mojo"; cat .work/build.err; exit 1; }
done
[ -x .venv/bin/python ] && export ORACLE_PY=${ORACLE_PY:-.venv/bin/python}
CASES=.work/cases scripts/check.sh
MOJO="$MOJO" scripts/mutants.sh
.work/t/api || { echo "FAIL api: tests/api.mojo"; exit 1; }
.work/t/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
echo "PASS ci"
