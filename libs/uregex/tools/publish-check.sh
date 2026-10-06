#!/usr/bin/env bash
# Publish gate (rules 1, 2, 4, 6 of the publishing standard): run before any push.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "FAIL: $*"; fail=1; }
[ -z "$(git status --short)" ] || say "working tree not clean"
git log --format=%B | grep -qiE '^co-authored-by|generated with \[claude' && say "attribution trailer in history"
git ls-files | grep -qE '^(\.work|\.venv)/|\.env$|\.mojopkg$' && say "ignored artefact tracked"
git ls-files -z | xargs -0 grep -lE '/home/[a-z]+/|api[_-]?key *=|token *= *["'"'"']|BEGIN (RSA|OPENSSH) PRIVATE' 2>/dev/null | grep -v '^tools/publish-check.sh$' | grep . && say "personal path or secret in tracked files"
for f in $(git ls-files 'src/*.mojo' 'tools/*.mojo' 'tools/*.py' 'tests/*.mojo' 'tests/*.py'); do head -3 "$f" | grep -q "Copyright" || say "no copyright header: $f"; done
for f in LICENSE NOTICE README.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md; do [ -f "$f" ] || say "missing $f"; done
grep -q "$(grep -m1 '^version' pyproject.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" CHANGELOG.md || say "CHANGELOG has no entry for pyproject version"
[ "$fail" = 0 ] && echo "publish-check: OK ($(git rev-parse --short HEAD))"
exit $fail
