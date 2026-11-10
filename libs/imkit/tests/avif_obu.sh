#!/usr/bin/env bash
# Stage 2 gate (AV1 OBU headers): tests/av1obu_info.mojo prints the parsed headers; they must equal ffmpeg's trace_headers bitstream filter
# (an independent AV1 syntax parser) on every fixture: seq profile, frame size (max_frame_*_minus_1 + 1), tiles (1 << tile_cols_log2 x 1 << tile_rows_log2),
# base_q_idx. A truncated AV1 payload must raise (no crash, no hang).
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}
timeout 300 "$M" build -I src tests/av1obu_info.mojo -o .work/av1obu_info 2> .work/av1obu_info.log || { grep -A6 -m3 error .work/av1obu_info.log | cut -c1-240; echo "FAIL build: tests/av1obu_info.mojo"; exit 1; }
exp() { timeout 30 ffmpeg -v trace -i "$1" -c copy -bsf:v trace_headers -f null - 2>&1 | sed 's/^\[[^]]*\] //' | awk '
  $2=="seq_profile"{p=$NF} $2=="max_frame_width_minus_1"{w=$NF+1} $2=="max_frame_height_minus_1"{h=$NF+1}
  $2=="tile_cols_log2"{c=$NF} $2=="tile_rows_log2"{r=$NF} $2=="base_q_idx" && q==""{q=$NF}
  END{print "seq profile " p; print "frame size " w "x" h; print "tiles " 2^c "x" 2^r; print "base_q_idx " q}'; }
fails=0
for f in $F/*.avif; do
  e=$(exp "$f"); g=$(timeout 10 .work/av1obu_info "$f" 2>&1 | grep -E '^(seq profile|frame size|tiles|base_q_idx) ' || true)
  if [ "$e" = "$g" ]; then echo "ok   $f"; else echo "FAIL $f:"; diff <(echo "$e") <(echo "$g") | head -10 || true; timeout 10 .work/av1obu_info "$f" 2>&1 | grep -i error | head -2 || true; fails=$((fails + 1)); fi
done
[ $fails = 0 ] && echo "PASS avif_obu" || { echo "FAIL avif_obu: $fails"; exit 1; }
