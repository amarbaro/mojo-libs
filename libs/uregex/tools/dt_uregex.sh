#!/usr/bin/env bash
# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
# uregex side of tools/difftest-real.sh: stdin lines -> NUL-separated texts -> .work/uregex-cli, answers bracketed.
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:?usage: dt_uregex.sh PATTERN_NAME}
tmp=.work/difftest/texts-$name
mkdir -p .work/difftest
./.venv/bin/python3 -c 'import sys; sys.path.insert(0,"tools"); from difftest import TOKENIZER_PATTERNS as P; sys.stdout.write(P[sys.argv[1]])' "$name" > "$tmp.pat"
tr '\n' '\0' | head -c -1 > "$tmp.txt"
.work/uregex-cli "$(cat "$tmp.pat")" "$tmp.txt" | awk '{ print "[" $0 "]" }'
