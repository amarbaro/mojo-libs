#!/usr/bin/env bash
# matrix-issues.sh RESULTS [--groups]: group the failed cells of a matrix run by the first `error:` line (error-line.sh
# --key: paths, line numbers and addresses stripped) and keep ONE issue per group in $GH_REPO: open or update it with the
# libraries listed, reopen it if it was closed, close the groups that went green. An issue is found by the hidden
# marker `<!-- matrix-group:HASH -->` in its body, never by title. --groups prints the groups and touches nothing.
# Env: GH (default gh; tests put a fake here), GH_REPO + GH_TOKEN as gh needs them, RUN_URL (linked in the body).
set -euo pipefail
res=${1:?usage: matrix-issues.sh RESULTS [--groups]}; mode=${2:-}
root=$(cd "$(dirname "$0")/.." && pwd); GH=${GH:-gh}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for j in "$res"/*.json; do  # one line per failed cell: HASH <TAB> KEY <TAB> LIB CHANNEL
  [ "$(jq -r .status "$j")" = fail ] || continue
  lib=$(jq -r .lib "$j"); ch=$(jq -r .channel "$j"); k=$("$root/scripts/error-line.sh" "$res/$lib-$ch.log" --key)
  printf '%s\t%s\t%s %s\n' "$(printf %s "$k" | sha1sum | cut -c1-12)" "$k" "$lib" "$ch"
done | sort > "$tmp/cells.tsv" 2>/dev/null || true
[ -s "$tmp/cells.tsv" ] || : > "$tmp/cells.tsv"
groups() { cut -f1,2 "$tmp/cells.tsv" | sort -u; }
if [ "$mode" = --groups ]; then
  groups | while IFS=$'\t' read -r h k; do echo "group $h | $k | $(awk -F'\t' -v h="$h" '$1==h{printf "%s%s", s, $3; s=", "}' "$tmp/cells.tsv")"; done
  echo "groups: $(groups | wc -l)"; exit 0
fi
"$GH" label create matrix --color B60205 --description "weekly matrix failure group" >/dev/null 2>&1 || true
"$GH" issue list --label matrix --state all --limit 300 --json number,state,body > "$tmp/issues.json"
find_issue() { jq -r --arg m "<!-- matrix-group:$1 -->" '[.[] | select(.body | contains($m))][0] | if . then "\(.number) \(.state)" else empty end' "$tmp/issues.json"; }
while IFS=$'\t' read -r h k; do
  body="$tmp/body-$h.md"
  { echo "<!-- matrix-group:$h -->"; echo "First error: \`$k\`"; echo; echo "| library | channel |"; echo "|---|---|"
    awk -F'\t' -v h="$h" '$1==h{split($3,a," "); print "| " a[1] " | " a[2] " |"}' "$tmp/cells.tsv"
    [ -z "${RUN_URL:-}" ] || { echo; echo "Run: $RUN_URL"; }; } > "$body"
  title="matrix: ${k:0:90}"; f=$(find_issue "$h" || true)
  if [ -z "$f" ]; then "$GH" issue create --title "$title" --body-file "$body" --label matrix >/dev/null; echo "opened $h"
  else n=${f%% *}; "$GH" issue edit "$n" --body-file "$body" >/dev/null
    [ "${f##* }" != CLOSED ] || { "$GH" issue reopen "$n" >/dev/null; echo "reopened $h #$n"; }
    echo "updated $h #$n"; fi
done < <(groups)
jq -r '.[] | select(.state == "OPEN") | "\(.number) \(.body | capture("<!-- matrix-group:(?<h>[0-9a-f]+) -->").h // "")"' "$tmp/issues.json" | while read -r n h; do
  [ -n "$h" ] || continue
  groups | cut -f1 | grep -qx "$h" || { "$GH" issue close "$n" --comment "Green in the latest matrix run." >/dev/null; echo "closed $h #$n"; }
done
