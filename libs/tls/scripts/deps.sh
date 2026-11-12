#!/usr/bin/env bash
# Fetch the Mojo libraries mojo-tls imports ([tool.mojo] deps in pyproject.toml) into .work/deps, each pinned to a commit.
# DEPS_BASE overrides the clone base (a directory holding local checkouts, for offline work). A fetched dir is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
base="${DEPS_BASE:-https://github.com/amarbaro}"
while read -r repo sha; do
  d=.work/deps/$repo
  [[ -e $d/src ]] && continue
  rm -rf "$d" && git init -q "$d"
  { git -C "$d" fetch -q --depth 1 "$base/$repo" "$sha" && git -C "$d" checkout -q FETCH_HEAD; } \
    || { echo "FAIL setup: fetch $repo $sha"; exit 1; }
done <<'PINS'
mojo-aio 7b2dba77aa53b4208b6518c0a634c0f5be028736
PINS
echo "PASS deps"
