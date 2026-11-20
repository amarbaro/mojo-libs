#!/usr/bin/env bash
# ci-all.sh [LIB...]: run libs/<name>/scripts/ci.sh for every library (or the named ones), one PASS/FAIL row per library, exit 1 on
# any FAIL. JOBS=n runs n libraries at once (default 1). Logs: .work/ci-all/<lib>.log. GPU libraries (imkit, vattn, amdgpu) go
# through gpu-wait when it is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; out=$root/.work/ci-all; mkdir -p "$out"; rm -f "$out"/*.row
libs=("$@"); ((${#libs[@]})) || mapfile -t libs < <(ls libs)
one() {
  local l=$1 t0=$SECONDS s=PASS run=(bash scripts/ci.sh)
  case $l in imkit|vattn|amdgpu) command -v gpu-wait >/dev/null && run=(gpu-wait run --timeout 1500 --mem 8 -- bash scripts/ci.sh);; esac
  (cd "libs/$l" && "${run[@]}") > "$out/$l.log" 2>&1 || s=FAIL
  printf '%s\t%s\t%ss\t%s\n' "$s" "$l" $((SECONDS - t0)) "$(awk '/^(PASS|FAIL)/{x=$0} END{print x}' "$out/$l.log")" > "$out/$l.row"
}
export -f one; export root out
printf '%s\n' "${libs[@]}" | xargs -P "${JOBS:-1}" -I{} bash -c 'one {}'
cat "$out"/*.row | sort -k2 | column -t -s $'\t'
fails=$(cat "$out"/*.row | awk -F'\t' '$1 == "FAIL"' | wc -l)
echo "ci-all: $((${#libs[@]} - fails))/${#libs[@]} PASS"
[ "$fails" = 0 ] || { echo "FAIL ci-all: $fails librar$([ "$fails" = 1 ] && echo y || echo ies) failed, logs in .work/ci-all/"; exit 1; }
