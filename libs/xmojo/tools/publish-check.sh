#!/usr/bin/env bash
# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
# Publish gate (rules 1, 2, 4, 6, 9, 11, 13 of the publishing standard): run before any push.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "FAIL: $*"; fail=1; }
[ -z "$(git status --short)" ] || say "working tree not clean"
git log --format=%B | grep -qiE '^co-authored-by|generated with \[claude' && say "attribution trailer in history"
git ls-files | grep -qE '^(\.work|\.pixi|\.venv)/|\.env$|\.mojopkg$|\.mojoc$' && say "ignored artefact tracked"
git ls-files -z | xargs -0 grep -lE '/home/[a-z]+/|api[_-]?key *=|token *= *["'"'"']|BEGIN (RSA|OPENSSH) PRIVATE' 2>/dev/null | grep -v '^tools/publish-check.sh$' | grep . && say "personal path or secret in tracked files"
for f in $(git ls-files 'src/*.mojo' 'tools/*.mojo' 'tools/*.py' 'tools/*.sh' 'tests/*.mojo'); do head -3 "$f" | grep -q "Copyright" || say "no copyright header: $f"; done
for f in LICENSE NOTICE README.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md tests/fixtures/SOURCES.md; do [ -f "$f" ] || say "missing $f"; done
v=$(grep -m1 '^version' pixi.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
grep -q "\[v$v\]" CHANGELOG.md || say "CHANGELOG has no entry for pixi version $v"
grep -q "version: $v" recipe.yaml || say "recipe version is not $v"
[ -f "docs/releases/v$v.md" ] || say "no release note docs/releases/v$v.md"
grep -q '\[yyyy\]\|\[name of copyright owner\]' LICENSE && say "LICENSE appendix still has the template placeholders"
grep -q 'github.com/amarbaro/xmojo' recipe.yaml || say "recipe homepage/repository not github.com/amarbaro/xmojo"
"$HOME/iTools/bin/gh-actions-runtime" . || say "workflow action on a deprecated runtime (gh-actions-runtime)"
[ "$fail" = 0 ] && echo "publish-check: OK ($(git rev-parse --short HEAD))"
exit $fail
