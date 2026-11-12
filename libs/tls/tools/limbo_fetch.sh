#!/usr/bin/env bash
# Fetches x509-limbo's limbo.json (pinned commit) into .work/limbo/ with gh and converts it to cases.txt.
# 40 MB, not committed. Needs network once.
set -euo pipefail
cd "$(dirname "$0")/.."
REF=f399b0537a1961462338c26690af6236f677e8cf
mkdir -p .work/limbo
gh api "repos/C2SP/x509-limbo/contents/limbo.json?ref=$REF" -H 'Accept: application/vnd.github.raw' > .work/limbo/limbo.json
# validation time for cases that name none: a fixed instant, so verdicts do not drift with the clock
python3 -I tools/limbo_convert.py .work/limbo/limbo.json .work/limbo/cases.txt 1794000000
