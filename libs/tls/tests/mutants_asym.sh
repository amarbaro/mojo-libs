#!/usr/bin/env bash
# Mutation gate: every line of tests/mutants_asym.txt ("file<TAB>from<TAB>to<TAB>runner<TAB>args...") edits one line of a copy of src/ and the named
# test binary must then FAIL (non-zero exit). A mutant that does not build is reported INVALID, one that survives is a gate failure.
# usage: tests/mutants_asym.sh [id ...]   (ids are 1-based line numbers; default all, 8 at a time)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/mut
list=tests/mutants_asym.txt
ids=("$@"); [ ${#ids[@]} -gt 0 ] || ids=($(seq 1 "$(grep -c . $list)"))

one() {
  local id=$1 line file from to runner args
  line=$(sed -n "${id}p" tests/mutants_asym.txt)
  IFS=$'\t' read -r file from to runner args <<<"$line"
  local d=.work/mut/$id
  rm -rf "$d"; mkdir -p "$d"; cp -r src "$d/src"
  F="$d/src/tls/asym/$file" FROM="$from" TO="$to" python3 -I -c '
import os,sys
p=os.environ["F"]; s=open(p).read(); a=os.environ["FROM"]
if s.count(a)!=1: sys.exit("mutant %s: pattern found %d times"%(p,s.count(a)))
open(p,"w").write(s.replace(a,os.environ["TO"]))' || { echo "INVALID $id: pattern"; return 0; }
  local main=tests/$runner.mojo; [ "$runner" != oracle ] || main=tests/tool.mojo
  SRC="$d/src" tools/mb.sh "$main" "$d/bin" >"$d/build.txt" 2>&1 || { echo "INVALID $id ($file): does not build"; return 0; }
  local cmd=("$d/bin" $args)
  if [ "$runner" = oracle ]; then mkdir -p "$d/oracle"; cp .work/oracle/rsa*.pem "$d/oracle/" 2>/dev/null || true
    cmd=(env T="$d/bin" ORACLE_DIR="$d/oracle" ORACLE_N=2 tests/oracle.sh); fi
  if timeout 280 "${cmd[@]}" >"$d/run.txt" 2>&1; then echo "SURVIVED $id ($file: $from)"; else echo "KILLED $id ($file): $(grep -m1 -E '^FAIL' "$d/run.txt" || echo 'exit non-zero')"; fi
}
export -f one
printf '%s\n' "${ids[@]}" | xargs -P 8 -I{} bash -c 'one {}' | sort -V | tee .work/mutants-out.txt
if grep -qE '^(SURVIVED|INVALID)' .work/mutants-out.txt; then echo "FAIL mutants: survivor or invalid mutant"; exit 1; fi
echo "PASS mutants: $(grep -c ^KILLED .work/mutants-out.txt) killed"
