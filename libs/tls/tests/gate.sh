#!/usr/bin/env bash
# Lane 2 gate (src/tls/asym): Wycheproof vectors, RFC/known-answer + round-trip checks, openssl cross-checks, mutants.
# usage: tests/gate.sh [wycheproof-dir]   (default .work/wycheproof, a shallow clone of github.com/C2SP/wycheproof)
set -euo pipefail
cd "$(dirname "$0")/.."
wyc=${1:-.work/wycheproof}
fail() { echo "FAIL $1: $2"; exit 1; }
[ -d "$wyc/testvectors_v1" ] || fail wycheproof "no $wyc/testvectors_v1 (git clone --depth 1 https://github.com/C2SP/wycheproof $wyc)"
mkdir -p .work
python3 -I tools/wyc2cases.py "$wyc/testvectors_v1" .work/vectors.txt >/dev/null || fail cases "converter"
for t in vectors kat tool; do
  [ -f "tests/$t.mojo" ] || continue
  tools/mb.sh "tests/$t.mojo" ".work/$t" || fail "build $t" "see output"
done
.work/vectors .work/vectors.txt || fail wycheproof "see FAIL lines"
[ ! -x .work/kat ] || .work/kat || fail kat "see FAIL lines"
[ ! -f tests/oracle.sh ] || tests/oracle.sh || fail oracle "see FAIL lines"
tests/mutants.sh || fail mutants "survivor"
echo "PASS gate"
