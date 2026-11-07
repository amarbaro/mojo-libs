#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${MOJO:-}" ]; then
  command -v uv >/dev/null || { echo 'FAIL setup: uv not installed'; exit 1; }
  uv sync -q || { echo 'FAIL setup: uv sync'; exit 1; }
  MOJO=.venv/bin/mojo
fi
"$MOJO" --version
mkdir -p .work/t
for t in tests/cases:.work/cases tests/api:.work/t/api examples/quickstart:.work/t/quickstart tests/fuzz_probe:.work/t/fuzz_probe; do
  scripts/cap.sh "$MOJO" build -O3 -I src ${MOJO_FLAGS:-} "${t%%:*}.mojo" -o "${t##*:}" > .work/build.err 2>&1 || { echo "FAIL build: ${t%%:*}.mojo"; head -50 .work/build.err; exit 1; }
done
CASES=.work/cases scripts/check.sh | tee .work/gate.txt
MOJO="$MOJO" scripts/mutants.sh | tee .work/mutants.txt
scripts/cap.sh .work/t/api
scripts/cap.sh .work/t/quickstart
python3 -I tools/oracle_fuzz.py .work/t/fuzz 7 5000
scripts/cap.sh .work/t/fuzz_probe .work/t/fuzz.bin > .work/t/fuzz.got
diff -u .work/t/fuzz.exp .work/t/fuzz.got || { echo 'FAIL fuzz differential'; exit 1; }
echo 'PASS 5/5'
echo 'PASS ci'
