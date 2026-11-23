#!/usr/bin/env bash
# fs-gate.sh: run one full-stack gate and write its receipt (plan Brain/mojo-cv/plans/2026-11-23-fullstack-plan.md, 7.3).
# usage: scripts/fs-gate.sh ID [--cwd DIR] [--in FILE]... [--need PATH]... [--expect ERE]... [--forbid ERE]... -- CMD [ARG...]
#   ST      stage dir whose entries (symlinks mojo-libs, mojo-faces, mojo-supervision, ...) are the roots under test;
#           default $PJ/mojo-libs/.work/fs/stage/base. CMD runs with MOJO_PROJECTS=$ST, the sibling root the scripts read.
#   --in    an input file: its sha256 goes in the receipt (missing = BLOCK)
#   --need  a precondition path (missing = BLOCK)
#   --expect an ERE every one of which must match a log line; --forbid an ERE no line may match (default ^FAIL)
# Receipt: $RC/ID.log (CMD output, then the verdict) and $RC/ID.json (cwd, roots with real path, HEAD and dirty count,
# inputs with sha256, exit code, verdict). Verdict: BLOCK when a precondition is missing or CMD exits 3 printing a
# BLOCK line (exit 3); PASS when CMD exits 0, every --expect matches and no --forbid matches (exit 0); else FAIL (exit 1).
# A skip is never a pass: a log line starting SKIP fails the gate.
set -euo pipefail
id=${1:?usage: fs-gate.sh ID [opts] -- CMD}; shift
PJ=${FS_PJ:-$HOME/Projects/mojo}  # not $PJ: the login shell sets PJ=~/Projects
ST=${ST:-$PJ/mojo-libs/.work/fs/stage/base}
RC=${RC:-$PJ/mojo-libs/.work/fs/receipts}
cwd=$PWD; ins=(); needs=(); expects=(); forbids=()
while [ $# -gt 0 ]; do
  case $1 in
    --cwd) cwd=$2; shift 2;;
    --in) ins+=("$2"); shift 2;;
    --need) needs+=("$2"); shift 2;;
    --expect) expects+=("$2"); shift 2;;
    --forbid) forbids+=("$2"); shift 2;;
    --) shift; break;;
    *) echo "FAIL usage: unknown option $1" >&2; exit 2;;
  esac
done
[ $# -gt 0 ] || { echo "FAIL usage: no command after --" >&2; exit 2; }
[ ${#forbids[@]} -gt 0 ] || forbids=('^FAIL')
mkdir -p "$RC"; log=$RC/$id.log; json=$RC/$id.json; : > "$log"

roots='[]'
if [ -d "$ST" ]; then
  for r in "$ST"/*; do
    [ -e "$r" ] || continue
    real=$(readlink -f "$r"); head=$(git -C "$r" rev-parse HEAD 2>/dev/null || echo none)
    dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
    roots=$(jq -c --arg n "${r##*/}" --arg p "$real" --arg h "$head" --argjson d "$dirty" '. + [{name:$n, real:$p, head:$h, dirty:$d}]' <<< "$roots")
  done
fi
inputs='[]'; block=""
for f in ${ins[@]+"${ins[@]}"}; do
  if [ -f "$f" ]; then s=$(sha256sum "$f" | cut -d' ' -f1); else s=missing; block="input $f missing"; fi
  inputs=$(jq -c --arg p "$f" --arg s "$s" '. + [{path:$p, sha256:$s}]' <<< "$inputs")
done
for p in ${needs[@]+"${needs[@]}"}; do [ -e "$p" ] || block="precondition $p missing"; done
[ -d "$ST" ] || block="stage $ST missing"
[ -d "$cwd" ] || block="cwd $cwd missing"

t0=$(date +%s); rc=0
if [ -z "$block" ]; then
  echo "# fs-gate $id cwd=$cwd ST=$ST cmd: $*" >> "$log"
  (cd "$cwd" && MOJO_PROJECTS=$ST "$@") >> "$log" 2>&1 || rc=$?
fi
t1=$(date +%s)

if [ -n "$block" ]; then verdict="BLOCK $id: $block"; rc=3
elif [ $rc = 3 ] && b=$(grep -m1 '^BLOCK' "$log"); then verdict="BLOCK $id: ${b#BLOCK }"
elif [ $rc != 0 ]; then verdict="FAIL $id: exit $rc"
else
  verdict="PASS $id"
  for e in ${expects[@]+"${expects[@]}"}; do grep -Eq -- "$e" "$log" || { verdict="FAIL $id: expected line /$e/ absent"; break; }; done
  if [ "${verdict%% *}" = PASS ]; then
    for e in "${forbids[@]}" '^SKIP'; do
      if l=$(grep -Em1 -- "$e" "$log"); then verdict="FAIL $id: forbidden line: ${l:0:160}"; break; fi
    done
  fi
fi
echo "$verdict" >> "$log"
jq -n --arg id "$id" --arg cwd "$cwd" --arg real "$(readlink -f "$cwd" 2>/dev/null || echo "$cwd")" --arg st "$ST" \
  --arg cmd "$*" --argjson roots "$roots" --argjson inputs "$inputs" --argjson rc "$rc" --arg v "$verdict" \
  --argjson t0 "$t0" --argjson t1 "$t1" --arg host "$(uname -n)" \
  '{id:$id, cwd:$cwd, cwd_real:$real, stage:$st, cmd:$cmd, roots:$roots, inputs:$inputs, exit:$rc, verdict:$v,
    started:$t0, ended:$t1, wall_s:($t1-$t0), host:$host}' > "$json"
echo "$verdict"
case ${verdict%% *} in PASS) exit 0;; BLOCK) exit 3;; *) exit 1;; esac
