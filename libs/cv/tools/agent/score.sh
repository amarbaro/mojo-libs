#!/usr/bin/env bash
# score.sh DIR [parse args...]: G1 and G2 of docs/agent.md over the rec.sh steps in DIR.
# G1 truth = UI-tree nodes clickable+enabled. Per step: iou = truth boxes matched by a parsed box at IoU >= 0.5;
#    hit = truth boxes holding the centre of some parsed element (the agent could tap it); prec = parsed centres inside a truth box.
# G2 truth = the UI tree changed (after.xml != xml) and, separately, any pixel changed; pred = screenStuck progress.
# Prints one row per step to DIR/score.tsv and the totals.
set -euo pipefail
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
[ $# -ge 1 ] || FAIL usage "score.sh DIR [parse args]"
D=$1; shift
CV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B=$CV/.bin/mojo-cv; [ -x "$B" ] || FAIL bin "$B missing (tests/run.sh builds it)"
T=$D/.score; mkdir -p "$T"
boxes_xml() { awk -v RS='<node ' '/clickable="true"/ && /enabled="true"/ && match($0, /bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"/) {
  s = substr($0, RSTART+8, RLENGTH-9); gsub(/[^0-9]+/, " ", s); print s }' "$1"; }
boxes_json() { awk 'match($0, /"box":\[[0-9]+,[0-9]+,[0-9]+,[0-9]+\]/) { s = substr($0, RSTART+7, RLENGTH-8); gsub(",", " ", s); print s }' "$1"; }
i32() { od -An -t d4 -j 16 -v "$1" | tr -s ' \n' ' '; }
printf 'step\ttruth\tpred\tiou\thit\tprec_in\ttree_chg\tpix_chg\tprogress\n' > "$D/score.tsv"
for p in "$D"/step_????.png; do
  s=${p%.png}; n=${s##*/}
  [ -f "$s.after.png" ] && [ -f "$s.after.xml" ] || continue
  bash "$CV/scripts/img2mcv.sh" "$p" "$T/a.mcv" bgr; bash "$CV/scripts/img2mcv.sh" "$s.after.png" "$T/b.mcv" bgr
  "$B" screenParse "$T/p" "$T/a.mcv" ocr=0 "$@" >/dev/null || FAIL parse "$n"
  "$B" screenStuck "$T/q" "$T/a.mcv" "$T/b.mcv" >/dev/null || FAIL stuck "$n"
  g1=$(awk 'FNR==1 { f++ } f==1 { t[++nt] = $0 } f==2 { q[++np] = $0 }
    function iou(a, b,   A, B, ix, iy, in_) { split(a, A, " "); split(b, B, " ")
      ix = (A[3] < B[3] ? A[3] : B[3]) - (A[1] > B[1] ? A[1] : B[1]); iy = (A[4] < B[4] ? A[4] : B[4]) - (A[2] > B[2] ? A[2] : B[2])
      if (ix <= 0 || iy <= 0) return 0; in_ = ix * iy
      return in_ / ((A[3]-A[1])*(A[4]-A[2]) + (B[3]-B[1])*(B[4]-B[2]) - in_) }
    function inside(a, b,   A, B, cx, cy) { split(a, A, " "); split(b, B, " "); cx = (B[1]+B[3])/2; cy = (B[2]+B[4])/2
      return cx >= A[1] && cx < A[3] && cy >= A[2] && cy < A[4] }
    END { for (i = 1; i <= nt; i++) { m = 0; h = 0; for (j = 1; j <= np; j++) { if (iou(t[i], q[j]) >= 0.5) m = 1; if (inside(t[i], q[j])) h = 1 }
            mi += m; hi += h }
          for (j = 1; j <= np; j++) { for (i = 1; i <= nt; i++) if (inside(t[i], q[j])) { pi++; break } }
          printf "%d\t%d\t%d\t%d\t%d", nt, np, mi, hi, pi }' <(boxes_xml "$s.xml") <(boxes_json "$T/p.json"))
  tc=0; cmp -s "$s.xml" "$s.after.xml" || tc=1
  pc=0; cmp -s <(tail -c +17 "$T/a.mcv") <(tail -c +17 "$T/b.mcv") || pc=1
  pr=$(i32 "$T/q" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$g1" "$tc" "$pc" "$pr" >> "$D/score.tsv"
done
awk -F'\t' 'NR>1 { n++; t+=$2; p+=$3; m+=$4; h+=$5; pin+=$6; if ($7==$9) at++; if ($8==$9) ap++ }
  END { if (!n) { print "FAIL score: no steps"; exit 1 }
        printf "steps %d | G1 truth %d pred %d | recall@iou0.5 %.3f | hit-recall %.3f | pred-in-truth %.3f | G2 agree tree %.3f pixel %.3f\n",
          n, t, p, m/t, h/t, (p ? pin/p : 0), at/n, ap/n }' "$D/score.tsv"
