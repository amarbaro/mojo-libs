#!/usr/bin/env bash
# ci-adopt-all.sh [LIB...]: on every library checkout (default: libs.txt) create branch `shared-ci` from main holding the
# caller ci.yml (scripts/ci-adopt.sh). Local commit only, never pushed. A temporary worktree does the commit, so the
# checkout a lane may be working in keeps its branch and files. KEEP_LOCAL libraries keep their own workflow.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); libs=${LIBS_DIR:-$root/..}
KEEP_LOCAL=" xmojo-public "   # pixi, daily schedule, timeout: not a lib-ci input (docs/ci.md)
(($#)) || { mapfile -t all < <(grep -v "^#" "$root/libs.txt" | grep .); set -- "${all[@]}"; }
for lib in "$@"; do
  [[ $KEEP_LOCAL == *" $lib "* ]] && { echo "keep  $lib (own workflow)"; continue; }
  r=$libs/$lib
  git -C "$r" rev-parse -q --verify shared-ci >/dev/null && { echo "skip  $lib (branch shared-ci exists)"; continue; }
  wt=$root/.work/adopt-wt/$lib; rm -rf "$wt"; mkdir -p "$(dirname "$wt")"
  git -C "$r" worktree add -q -b shared-ci "$wt" main
  "$root/scripts/ci-adopt.sh" "$lib" "$wt"
  git -C "$wt" add .github/workflows/ci.yml
  git -C "$wt" commit -q -F - <<MSG
ci: call the shared lib-ci workflow from mojo-libs

One reusable workflow replaces this copy, so a toolchain pin or a badge fix is made once for all
libraries. Same steps: checkout, setup-uv, scripts/ci.sh teed to ci.log under pipefail, the checks badge on main pushes.
MSG
  git -C "$r" worktree remove --force "$wt"
  echo "done  $lib $(git -C "$r" rev-parse --short shared-ci)"
done
