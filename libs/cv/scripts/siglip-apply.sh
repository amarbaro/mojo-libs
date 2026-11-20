#!/usr/bin/env bash
# siglip-apply.sh LIBRARY_DIR: sidecar `category:` becomes SigLIP's top-1 and `tags:` its tags for every picture that has a
# <picture>.labels.json beside it (scripts/siglip-labels.sh); the category the sidecar had goes to `library_category:` the first time
# (a second run keeps it). Rewrites only those frontmatter lines; idempotent, so it can run again after the labels change.
# Mario approved this 2026-11-16 (labels beat the library's own categories 0.80 to 0.40 on 40 pictures by eye).
set -euo pipefail
lib=${1:?FAIL usage: siglip-apply.sh LIBRARY_DIR}
[ -d "$lib/images" ] || { echo "FAIL input: $lib/images missing" >&2; exit 1; }
tab=$(mktemp); trap 'rm -f "$tab"' EXIT
# one row per labels json: sidecar path, category, tags as "a, b"; jq reads many files per call
find "$lib/images" -name '*.labels.json' -print0 | xargs -0 -n 500 jq -r '[input_filename, .cat_pred, (.tags | join(", "))] | @tsv' > "$tab"
n=0; changed=0
while IFS=$'\t' read -r j cat tags; do
  md=${j%.labels.json}.md; [ -f "$md" ] || { echo "FAIL sidecar: $md missing" >&2; exit 1; }
  awk -v cat="$cat" -v tags="$tags" '{ L[NR] = $0 }
    END { fm = 0
      for (i = 1; i <= NR; i++) { if (L[i] == "---") fm++; if (fm == 1) { if (L[i] ~ /^category:/) ci = i; if (L[i] ~ /^library_category:/) hl = 1; if (L[i] ~ /^tags:/) ti = i } }
      if (!ci || !ti) { print "FAIL frontmatter: no category: or tags: line" > "/dev/stderr"; exit 1 }
      for (i = 1; i <= NR; i++) {
        if (i == ci) { old = L[i]; sub(/^category: */, "", old); print "category: " cat; if (!hl) print "library_category: " old; continue }
        if (i == ti) { print "tags: [" tags "]"; continue }
        print L[i] } }' "$md" > "$md.tmp" || { rm -f "$md.tmp"; echo "FAIL awk: $md" >&2; exit 1; }
  if cmp -s "$md" "$md.tmp"; then rm -f "$md.tmp"; else mv "$md.tmp" "$md"; changed=$((changed + 1)); fi
  n=$((n + 1))
done < "$tab"
echo "PASS siglip-apply: $n sidecars checked, $changed rewritten"
