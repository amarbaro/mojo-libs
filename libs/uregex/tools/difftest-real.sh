#!/usr/bin/env bash
# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
# Real-text differential run: every tokenizer pattern, uregex against Python regex, over CORPUS (one text per
# line), through the difftest iTool. The first disagreement per pattern is a certificate in .work/difftest/.
# Complements tools/difftest.py, which draws random texts from a fixed alphabet.
set -euo pipefail
cd "$(dirname "$0")/.."
CORPUS=${1:?usage: tools/difftest-real.sh CORPUS_FILE}
DT=${DIFFTEST:-$HOME/iTools/bin/difftest}
mkdir -p .work/difftest
[ -x .work/uregex-cli ] || ./.venv/bin/mojo build tools/uregex-cli.mojo -I src -o .work/uregex-cli
fails=(); n=0
for name in $(./.venv/bin/python3 -c 'import sys; sys.path.insert(0,"tools"); from difftest import TOKENIZER_PATTERNS as P; print(" ".join(P))'); do
  n=$((n + 1))
  if "$DT" corpus "$CORPUS" "tools/dt_uregex.sh $name" "./.venv/bin/python3 tools/dt_regex.py $name" \
       --cert ".work/difftest/cert-$name.txt" > ".work/difftest/$name.log" 2>&1; then
    echo "ok $name: $(tail -1 ".work/difftest/$name.log")"
  else
    echo "DIFFER $name: .work/difftest/cert-$name.txt"; fails+=("$name")
  fi
done
[ ${#fails[@]} -eq 0 ] || { echo "FAIL ${#fails[@]}/$n ${fails[*]}"; exit 1; }
echo "PASS difftest-real: $n/$n patterns agree on $(wc -l < "$CORPUS") lines"
