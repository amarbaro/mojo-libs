#!/usr/bin/env bash
# Mojo bench vs its Python reference for a library that has tests/bench.mojo + tools/bench_*.py but no
# scripts/bench.sh. Builds -O3, then 3 alternating rounds; each side prints its own timed work, plus peak RSS.
# Per-library arguments and setup live in the case below. Usage: scripts/bench-pair.sh mojo-json
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)/$1; cd "$R"; W=.work/benchpair; mkdir -p $W
REF=tools/bench_oracle.py; [ -e $REF ] || REF=tools/bench_ref.py
PY=.venv/bin/python; [ -x $PY ] || PY=python3
.venv/bin/mojo build -O3 -I src $([ -d lib ] && echo -I lib) tests/bench.mojo -o $W/bench >$W/build.err 2>&1 \
  || { echo "FAIL build: $1"; head -20 $W/build.err; exit 1; }
pre() { :; }; ARGS=()
case $1 in
  mojo-amdgpu) ARGS=(/sys) ;;
  mojo-inotify) pre() { rm -rf $W/d; }; ARGS=($W/d) ;;
  mojo-sqlite) pre() { rm -f $W/b.db; }; ARGS=($W/b.db) ;;
  mojo-json) [ -e $W/in.json ] || $PY -I $REF make $W/in.json; ;;
esac
side() { pre; $PY -I -c 'import resource, subprocess, sys
out = subprocess.run(sys.argv[2:], capture_output=True, text=True, check=True).stdout.strip()
print("%-7s %s | peak RSS %d MB" % (sys.argv[1], out.replace("\n", " ; "), resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024))' "$@" \
  || { echo "FAIL run: $1"; exit 1; }; }
for i in 1 2 3; do
  if [ $1 = mojo-json ]; then for m in parse dumps; do side mojo $W/bench $m $W/in.json; side python $PY -I $REF $m $W/in.json; done
  else side mojo $W/bench "${ARGS[@]}"; side python $PY -I $REF "${ARGS[@]}"; fi
done
