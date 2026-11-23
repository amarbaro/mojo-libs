#!/usr/bin/env bash
# fs-manifest.sh: ownership and input manifest checks of the full-stack plan (Brain/mojo-cv/plans/2026-11-23-fullstack-plan.md 7.2).
# usage: scripts/fs-manifest.sh check                  licences/*.tsv have no empty field; inputs/MANIFEST.sha256 verifies;
#                                                      OWNERS.tsv gives every existing path at most one owner (G0.13)
#        scripts/fs-manifest.sh owner PATH...          print the owner of each repo-prefixed path (mojo-libs/..., iTools/...)
#        scripts/fs-manifest.sh own LANE REPO RANGE    every path changed in REPO (dir name under $PJ) over RANGE belongs to LANE (G1.8)
# OWNERS.tsv columns: glob, owner, from-phase, note. A glob is repo-prefixed; ** matches across /, * within one segment.
# The owner of a path is the matching row with the most literal characters; two owners tied on that count is a conflict.
set -euo pipefail
PJ=${FS_PJ:-$HOME/Projects/mojo}; FS=${FS:-$PJ/mojo-libs/.work/fs}; OWN=${OWNERS:-$FS/OWNERS.tsv}
[ -f "$OWN" ] || { echo "BLOCK fs-manifest: $OWN missing"; exit 3; }

root_of() {  # repo prefix -> directory
  case $1 in
    iTools) echo "$HOME/iTools";; vidcode) echo "$HOME/Projects/gpu-media/vidcode";; Models) echo "$HOME/Models";;
    *) echo "$PJ/$1";;
  esac
}
# stdin: repo-prefixed paths; stdout: path TAB owner (or - when unowned, CONFLICT:a,b on a tie)
owners() {
  awk -F'\t' -v OFS='\t' '
    NR == FNR { if (FNR == 1) next
      g = $1; lit = g; gsub(/\*/, "", lit); re = ""
      for (i = 1; i <= length(g); i++) { c = substr(g, i, 1)
        if (c == "*") { if (substr(g, i + 1, 1) == "*") { re = re ".*"; i++ } else re = re "[^/]*" }
        else if (index(".+?()[]{}|^$\\", c)) re = re "\\" c; else re = re c }
      n++; R[n] = "^" re "$"; O[n] = $2; L[n] = length(lit); next }
    { best = -1; who = "-"
      for (i = 1; i <= n; i++) if ($0 ~ R[i]) {
        if (L[i] > best) { best = L[i]; who = O[i] }
        else if (L[i] == best && O[i] != who && index(who, O[i]) == 0) who = (who ~ /^CONFLICT:/ ? who : "CONFLICT:" who) "," O[i] }
      print $0, who }' "$OWN" -
}

case ${1:-} in
check)
  bad=0
  for f in "$FS"/licences/*.tsv; do
    awk -F'\t' 'NR == 1 { n = NF; next } NF != n { print "FAIL licences: " FILENAME ":" NR " has " NF " fields, header " n; e = 1; next }
      { for (i = 1; i <= NF; i++) if ($i ~ /^[ ]*$/) { print "FAIL licences: " FILENAME ":" NR " field " i " empty"; e = 1 } }
      END { exit e }' "$f" || bad=1
    echo "ok licences $(basename "$f") $(($(wc -l < "$f") - 1)) rows"
  done
  if out=$(sha256sum -c --quiet "$FS/inputs/MANIFEST.sha256" 2>&1); then echo "ok inputs $(wc -l < "$FS/inputs/MANIFEST.sha256") hashes"
  else echo "$out" | head -5; echo "FAIL inputs: MANIFEST.sha256"; bad=1; fi
  dup=$(awk -F'\t' 'NR > 1 { if (($1 in o) && o[$1] != $2) print $1; o[$1] = $2 }' "$OWN")
  [ -z "$dup" ] || { echo "FAIL owners: glob with two owners: $dup"; bad=1; }
  # every existing path under the repos the manifest names: tracked files, plus .work/fs files of mojo-libs
  paths=$(for r in $(awk -F'\t' 'NR > 1 { split($1, a, "/"); print a[1] }' "$OWN" | sort -u); do
    d=$(root_of "$r"); [ -d "$d" ] || continue
    if [ "$r" = Models ]; then continue; fi
    git -C "$d" ls-files 2>/dev/null | sed "s#^#$r/#"
  done; (cd "$PJ" && find mojo-libs/.work/fs -type f -not -path '*/receipts/*' -not -path '*/stage/*' -not -path '*/tmp/*'))
  res=$(owners <<< "$paths")
  c=$(awk -F'\t' '$2 ~ /^CONFLICT/' <<< "$res")
  [ -z "$c" ] || { echo "$c" | head -10 | sed 's/^/FAIL owners: tie /'; bad=1; }
  echo "ok owners $(awk -F'\t' '$2 != "-"' <<< "$res" | wc -l) owned of $(wc -l <<< "$res") paths, $(($(wc -l < "$OWN") - 1)) rows"
  [ $bad = 0 ] && echo "PASS fs-manifest check" || { echo "FAIL fs-manifest check"; exit 1; } ;;
owner)
  shift; printf '%s\n' "$@" | owners ;;
own)
  lane=${2:?usage: own LANE REPO RANGE}; repo=${3:?}; range=${4:?}; d=$(root_of "$repo")
  [ -d "$d" ] || { echo "BLOCK fs-manifest own: $d missing"; exit 3; }
  ch=$(git -C "$d" diff --name-only "$range" | sed "s#^#$repo/#")
  [ -n "$ch" ] || { echo "FAIL fs-manifest own: no changed path in $repo $range (empty is not a pass)"; exit 1; }
  wrong=$(owners <<< "$ch" | awk -F'\t' -v l="$lane" '$2 != l')
  if [ -n "$wrong" ]; then echo "$wrong" | sed 's/^/FAIL own: /'; echo "FAIL fs-manifest own $lane $repo"; exit 1; fi
  echo "PASS fs-manifest own $lane $repo $(wc -l <<< "$ch") paths" ;;
*) echo "usage: fs-manifest.sh check | owner PATH... | own LANE REPO RANGE" >&2; exit 2 ;;
esac
