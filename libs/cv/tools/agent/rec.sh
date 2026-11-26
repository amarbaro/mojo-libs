#!/usr/bin/env bash
# rec.sh SERIAL OUT N [SEED]: record N random-tap steps on an Android phone for the agent perception gates (docs/agent.md).
# Per step: step_NNNN.png + .xml (before), one tap on a random enabled clickable UI-tree node, step_NNNN.after.png +
# .after.xml, step_NNNN.act (tap x y, package, node bounds, ms from tap to the after capture). Local apps only (ALLOW);
# a node whose text (own + next 3 nodes) matches DENY is never tapped; foreground outside ALLOW → launch the next allowed app.
# Taps only, no swipes (an edge swipe is the back gesture). uiautomator clips bounds to the screen and omits off-screen nodes.
set -euo pipefail
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
[ $# -ge 3 ] || FAIL usage "rec.sh SERIAL OUT N [SEED]"
S=$1 OUT=$2 N=$3 SEED=${4:-1}
ALLOW=(com.android.calculator2 com.android.deskclock com.android.calendar com.android.gallery3d com.android.music
  com.mediatek.filemanager com.android.soundrecorder)
DENY='delete|erase|reset|remove|format|send|share|call|account|sign|login|debug|developer|usb|wifi|wi-fi|bluetooth|airplane|uninstall'
mkdir -p "$OUT"
A() { adb -s "$S" "$@"; }
A get-state >/dev/null 2>&1 || FAIL adb "device $S not online"
cap() { A exec-out screencap -p > "$1" || FAIL screencap "$1"; }
dump() { A shell uiautomator dump /sdcard/rec.xml >/dev/null 2>&1 && A pull /sdcard/rec.xml "$1" >/dev/null 2>&1 || FAIL dump "$1"; }
launch() { A shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true; sleep 2; }
ai=0 miss=0
launch "${ALLOW[0]}"
for ((i = 0; i < N; i++)); do
  b=$(printf '%s/step_%04d' "$OUT" "$i")
  dump "$b.xml"
  pkg=$(awk -F'package="' 'NF>1{split($2,a,"\""); print a[1]; exit}' "$b.xml")
  if ! printf '%s\n' "${ALLOW[@]}" | awk -v p="$pkg" '$0==p{f=1} END{exit !f}'; then
    miss=$((miss + 1)); [ $miss -le 20 ] || FAIL foreground "20 relaunches without an allowed app (last $pkg)"
    ai=$(( (ai + 1) % ${#ALLOW[@]} )); launch "${ALLOW[$ai]}"; i=$((i - 1)); continue
  fi
  miss=0
  cap "$b.png"
  pick=$(awk -v RS='<node ' -v seed=$((SEED * 100003 + i)) -v deny="$DENY" '
    NR>1 { t[NR]=tolower($0) }
    NR>1 && /clickable="true"/ && /enabled="true"/ && match($0, /bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"/) { c[++n]=NR; bd[NR]=substr($0, RSTART+8, RLENGTH-9) }
    END { srand(seed); while (n > 0) { j = int(rand() * n) + 1; r = c[j]; w = t[r] t[r+1] t[r+2] t[r+3]
            if (w !~ deny) { print bd[r]; exit } c[j] = c[n]; n-- } }' "$b.xml")
  if [ -z "$pick" ]; then A shell input keyevent 4; echo "back - $pkg none 0" > "$b.act"; sleep 1
  else
    read -r x0 y0 x1 y1 <<< "$(printf '%s' "$pick" | tr -c '0-9' ' ')"
    x=$(( (x0 + x1) / 2 )) y=$(( (y0 + y1) / 2 ))
    t0=$(date +%s%N); A shell input tap "$x" "$y"; sleep 0.5
    echo "tap $x $y $pkg $x0,$y0,$x1,$y1 $(( ($(date +%s%N) - t0) / 1000000 ))" > "$b.act"
  fi
  cap "$b.after.png"; dump "$b.after.xml"
  [ $((i % 9)) -eq 8 ] && A shell input keyevent 4
  echo "step $i $pkg $(cat "$b.act")"
done
echo "ok rec: $N steps in $OUT"
