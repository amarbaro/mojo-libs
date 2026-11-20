#!/usr/bin/env bash
# deps-scan.sh [--write|--check]: the sibling-library edges found in libs/*/ ("<lib> <dep>" per line): ../<dep>/src or ../<dep>/lib in
# scripts, tests, tools and pixi.toml, and [tool.mojo] deps in pyproject.toml. --write refreshes deps.tsv (the map CI uses to
# run a library's dependents); --check fails when deps.tsv is stale; no flag prints the edges.
set -euo pipefail
cd "$(dirname "$0")/.."
edges() {
  local l d
  for l in $(ls libs); do
    { GRAPH_FIRST_ALLOW=1 grep -rhoE '\.\./[a-z0-9-]+/(src|lib)\b' "libs/$l/scripts" "libs/$l/tests" "libs/$l/tools" "libs/$l/pixi.toml" 2>/dev/null | sed -E 's#\.\./([a-z0-9-]+)/.*#\1#' || true
      { sed -n '/^\[tool\.mojo\]/,/^\[[a-z]/p' "libs/$l/pyproject.toml" 2>/dev/null | grep -oE '"mojo-[a-z0-9-]+' | sed 's/"mojo-//' || true; }
    } | sort -u | while read -r d; do [ -n "$d" ] && [ "$d" != "$l" ] && [ -d "libs/$d" ] && echo "$l $d"; done
  done
}
table() {  # edges -> "<lib>\t<dep dep ...>"
  edges | awk '{d[$1] = d[$1] (d[$1] ? " " : "") $2} END {for (l in d) printf "%s\t%s\n", l, d[l]}' | sort
}
case ${1:-} in
  --write) { echo "# lib<TAB>sibling libraries it uses (scripts/deps-scan.sh --write); CI runs a library when one of these changes"; table; } > deps.tsv; echo "wrote deps.tsv" ;;
  --check) diff <(grep -v '^#' deps.tsv) <(table) >/dev/null || { echo "FAIL deps: deps.tsv is stale, run scripts/deps-scan.sh --write"; diff <(grep -v '^#' deps.tsv) <(table) || true; exit 1; }
           echo "PASS deps: $(grep -vc '^#' deps.tsv) libraries with sibling dependencies" ;;
  *) edges ;;
esac
