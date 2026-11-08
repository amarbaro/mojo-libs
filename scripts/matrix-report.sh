#!/usr/bin/env bash
# matrix-report.sh RESULTS OUT [LIBS]: RESULTS holds the cells' LIB-CHANNEL.json (matrix-cell.sh). Writes OUT/status.md
# (lib, stable, nightly, first error) and OUT/shields/LIB.json, a shields.io endpoint badge per library, in libs.txt order.
# A cell with no json is "missing" (job cancelled or lost), never silently green.
set -euo pipefail
res=${1:?usage: matrix-report.sh RESULTS OUT [LIBS]}; out=${2:?}; libs=${3:-$(dirname "$0")/../libs.txt}
mkdir -p "$out/shields"
st() { [ -f "$res/$1-$2.json" ] && jq -r .status "$res/$1-$2.json" || echo missing; }
{ echo "| library | stable | nightly | first error |"; echo "|---|---|---|---|"; } > "$out/status.md"
nfail=0; n=0
for lib in $(grep -v '^#' "$libs" | grep .); do
  s=$(st "$lib" stable); t=$(st "$lib" nightly); n=$((n+1))
  e=$( { [ -f "$res/$lib-stable.json" ] && jq -r .error "$res/$lib-stable.json"; [ -f "$res/$lib-nightly.json" ] && jq -r .error "$res/$lib-nightly.json"; } 2>/dev/null | grep . | head -1 || true)
  e=${e//|/\\|}; e=${e//\`/\'}
  printf '| %s | %s | %s | %s |\n' "$lib" "$s" "$t" "${e:+\`$e\`}" >> "$out/status.md"
  color=brightgreen; [ "$t" = pass ] || color=yellowgreen; [ "$t" = fail ] && color=orange
  [ "$s" = pass ] || { color=red; nfail=$((nfail+1)); }
  jq -n --arg m "stable $s, nightly $t" --arg c "$color" '{schemaVersion:1,label:"mojo",message:$m,color:$c}' > "$out/shields/$lib.json"
done
echo "matrix: $n libraries, $nfail with a failing or missing stable cell"
