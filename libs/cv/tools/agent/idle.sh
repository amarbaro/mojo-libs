#!/usr/bin/env bash
# idle.sh SERIAL OUT [K=5] [GAP=1.7]: noise control for G2 (docs/agent.md). For each local app, K pairs of screenshots GAP s
# apart with no input, then screenStuck at several minfrac values. A progress=1 here is a false alarm (clock, cursor, animation).
# Prints OUT/res.txt rows: app minfrac progress changed-bbox, and the false-progress count per minfrac.
set -euo pipefail
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
[ $# -ge 2 ] || FAIL usage "idle.sh SERIAL OUT [K] [GAP]"
S=$1 OUT=$2 K=${3:-5} GAP=${4:-1.7}
CV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B=$CV/.bin/mojo-cv; [ -x "$B" ] || FAIL bin "$B missing"
APPS=(com.android.deskclock com.android.calendar com.android.music com.android.calculator2 com.mediatek.filemanager com.android.soundrecorder)
A() { adb -s "$S" "$@"; }
A get-state >/dev/null 2>&1 || FAIL adb "device $S not online"
mkdir -p "$OUT"; : > "$OUT/res.txt"; k=0
for a in "${APPS[@]}"; do
  A shell monkey -p "$a" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true; sleep 3
  for ((j = 0; j < K; j++)); do
    A exec-out screencap -p > "$OUT/$k.a.png"; sleep "$GAP"; A exec-out screencap -p > "$OUT/$k.b.png"
    bash "$CV/scripts/img2mcv.sh" "$OUT/$k.a.png" "$OUT/$k.a.mcv" bgr; bash "$CV/scripts/img2mcv.sh" "$OUT/$k.b.png" "$OUT/$k.b.mcv" bgr
    for mf in 0.005 0.001 0.0005 0.0001; do
      "$B" screenStuck "$OUT/q" "$OUT/$k.a.mcv" "$OUT/$k.b.mcv" minfrac=$mf >/dev/null || FAIL stuck "$k"
      echo "$a $mf $(od -An -t d4 -j16 -N4 "$OUT/q" | tr -d ' ') $(od -An -t d4 -j16 "$OUT/q.1" | tr -s ' ')" >> "$OUT/res.txt"
    done
    k=$((k + 1))
  done
done
awk '{fp[$2] += $3; n[$2]++} END {for (m in n) print "minfrac", m, "false-progress", fp[m] "/" n[m]}' "$OUT/res.txt" | sort -k2 -g
