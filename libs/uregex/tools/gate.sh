#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
./.venv/bin/mojo build tools/uregex-cli.mojo -I src -o .work/uregex-cli
./.venv/bin/mojo run -I src tests/test_uregex.mojo
./.venv/bin/python3 tools/difftest.py --n 5000 --maxlen 80
