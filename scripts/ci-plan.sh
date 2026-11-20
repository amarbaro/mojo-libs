#!/usr/bin/env bash
# ci-plan.sh [BASE]: JSON array of the libraries whose CI must run: the ones with changes under libs/<name>/ since BASE plus every
# library that depends on one of them (deps.tsv, transitively). No BASE, an unknown BASE, or a change outside libs/ (scripts/,
# .github/, deps.tsv, ...): every library. Docs-only root changes (README.md, docs/, CHANGELOG.md): none.
set -euo pipefail
cd "$(dirname "$0")/.."
base=${1:-}
all=$(ls libs)
if [ -z "$base" ] || [[ $base =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  changed=$all
else
  files=$(git diff --name-only "$base" HEAD)
  if grep -qvE '^(libs/|README\.md$|docs/|CHANGELOG\.md$|$)' <<<"$files"; then changed=$all
  else changed=$(grep '^libs/' <<<"$files" | cut -d/ -f2 | sort -u || true); fi
fi
sel=" $(echo $changed) "
grew=1
while [ $grew = 1 ]; do
  grew=0
  while IFS=$'\t' read -r l deps; do
    [[ -z $l || $l == \#* || $sel == *" $l "* ]] && continue
    for d in $deps; do
      if [[ $sel == *" $d "* ]]; then sel+="$l "; grew=1; break; fi
    done
  done < deps.tsv
done
{ printf '%s\n' $sel | sort -u | grep . || true; } | jq -R . | jq -sc .
