#!/usr/bin/env bash
# matrix-cell.sh LIB CHANNEL OUT: one cell of the weekly matrix. Clones the library, runs its scripts/ci.sh on the
# stable pin (channel stable) or on a nightly Mojo handed over through MOJO= (channel nightly), writes
# OUT/LIB-CHANNEL.log and OUT/LIB-CHANNEL.json {lib, channel, status: pass|fail|na, error}.
# na = the library's ci.sh has no MOJO= override, so a nightly cannot be selected (the only existing mechanism).
# Env: MATRIX_SRC clone source (default https://github.com/amarbaro/<LIB minus -public>.git; a directory works too),
#      NIGHTLY_MOJO an installed nightly mojo (default: install one into OUT/nightly-venv),
#      CELL_TIMEOUT seconds for setup+ci (default 2400). apt rows of ci-setup.tsv run only when CI is set.
set -euo pipefail
lib=${1:?usage: matrix-cell.sh LIB CHANNEL OUT}; ch=${2:?}; out=$(mkdir -p "${3:?}" && cd "$3" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
case $ch in stable|nightly) ;; *) echo "FAIL args: channel $ch is not stable|nightly"; exit 2;; esac
src=${MATRIX_SRC:-https://github.com/amarbaro/${lib%-public}.git}
w=$out/work/$lib-$ch; log=$out/$lib-$ch.log; : > "$log"
finish() {  # STATUS ERROR
  jq -n --arg lib "$lib" --arg ch "$ch" --arg st "$1" --arg err "$2" '{lib:$lib,channel:$ch,status:$st,error:$err}' > "$out/$lib-$ch.json"
  echo "$lib $ch $1${2:+ | $2}"
}
rm -rf "$w"; mkdir -p "$(dirname "$w")"
if [ -d "$src" ]; then git clone -q --no-hardlinks "$src" "$w" >>"$log" 2>&1; else git clone -q --depth 1 "$src" "$w" >>"$log" 2>&1; fi \
  || { finish fail "clone failed: $src"; exit 0; }
if [ "$ch" = nightly ] && ! grep -q MOJO "$w/scripts/ci.sh" 2>/dev/null; then
  echo "scripts/ci.sh has no MOJO= override" >> "$log"; finish na "no MOJO= override in scripts/ci.sh"; exit 0
fi
# awk, not `read`: tab is IFS whitespace, so `read` collapses an empty apt column and files the pre command under apt
apt=$(awk -F'\t' -v l="$lib" '$1 == l { print $2 }' "$root/ci-setup.tsv"); pre=$(awk -F'\t' -v l="$lib" '$1 == l { print $3 }' "$root/ci-setup.tsv")
run() { cd "$w"
  [ -z "$apt" ] || { [ -z "${CI:-}" ] && echo "skip apt (not CI): $apt" || { sudo apt-get update -q && sudo apt-get install -yq $apt; }; }
  if [ "$ch" = nightly ]; then   # same command as lib-ci.yml (scripts/test-ci.sh keeps them equal)
    if [ -z "${NIGHTLY_MOJO:-}" ]; then
      uv venv -q "$out/nightly-venv" && uv pip install -q --python "$out/nightly-venv/bin/python" --prerelease allow --index-strategy unsafe-best-match --extra-index-url https://whl.modular.com/nightly/simple/ mojo max
      NIGHTLY_MOJO=$out/nightly-venv/bin/mojo
    fi
    export MOJO=$NIGHTLY_MOJO
  else unset MOJO; fi
  [ -z "$pre" ] || bash -c "$pre"
  bash scripts/ci.sh
}
export -f run; export w apt pre ch out NIGHTLY_MOJO="${NIGHTLY_MOJO:-}"
set +e; timeout "${CELL_TIMEOUT:-2400}" bash -euo pipefail -c run 2>&1 | tee -a "$log"; rc=${PIPESTATUS[0]}; set -e
[ "$rc" != 124 ] || echo "FAIL timeout: cell exceeded ${CELL_TIMEOUT:-2400} s" >> "$log"
if [ "$rc" = 0 ]; then finish pass ""; else finish fail "$("$root/scripts/error-line.sh" "$log")"; fi
