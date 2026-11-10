#!/usr/bin/env bash
# Runs each library's scripts/bench.sh one at a time on a quiet box.
# Before each repo: wait until 1-min load < LOAD_MAX (default 1.5). Each run is capped at TMO s.
# Output: .work/bench/<repo>.log, summary line per repo on stdout.
# Usage: scripts/bench-all.sh [repo ...]   (default: every sibling mojo-* with scripts/bench.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=..; OUT=.work/bench; LOAD_MAX=${LOAD_MAX:-1.5}; TMO=${TMO:-300}
mkdir -p "$OUT"
repos=("$@")
if ((${#repos[@]} == 0)); then
  for s in "$ROOT"/mojo-*/scripts/bench.sh; do r=$(basename "$(dirname "$(dirname "$s")")")
    [[ $r == *-public || $r == *-lanes || $r == mojo-libs ]] || repos+=("$r"); done
fi
for r in "${repos[@]}"; do
  until awk -v m="$LOAD_MAX" '{exit !($1 < m)}' /proc/loadavg; do sleep 5; done
  echo "START $r load $(cut -d' ' -f1 /proc/loadavg) $(date +%T)"
  cmd=("$ROOT/$r/scripts/bench.sh")
  [ -x "${cmd[0]}" ] || cmd=(scripts/bench-pair.sh "$r")
  [ "$r" = mojo-csv ] && cmd=("$ROOT/$r/scripts/benchmark.sh")
  if timeout "$TMO" "${cmd[@]}" >"$OUT/$r.log" 2>&1; then echo "OK $r"
  else echo "FAIL $r: exit $? (see $OUT/$r.log)"; fi
done
