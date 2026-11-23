#!/usr/bin/env bash
# tests/bench_gpu.sh [BIG.mcv]: wall time of the per-image ops of the stock job, CPU against GPU (gpu=1), best of REPS runs inside one
# process (reps=N), on a 1080p fixture and on a 50 MP photo (default: the first .work/big/*.mcv, decoded by scripts/decode-stock.sh).
# GPU times include the upload and the download. The GPU rows run in one gpu-wait job (--shared: a small job beside the queue's).
# Writes .work/bench_gpu.md. Same outputs first: every GPU output is compared byte for byte with the CPU one.
set -euo pipefail
cd "$(dirname "$0")/.."
# gw LABEL CMD...: one gpu-wait job (shared, small VRAM), or the command itself when the caller already is a GPU job (tests/gpu_all.sh)
gw() { local l=$1; shift; if [ -n "${CV_IN_GPU_JOB:-}" ]; then "$@"; else gpu-wait run --shared --vram 4 --mem 8 --timeout 1800 --label "$l" -- "$@"; fi; }
bin=.bin/mojo-cv; reps=${REPS:-10}; w=.work/benchgpu; mkdir -p "$w"
big=${1:-$(ls .work/big/*.mcv | head -1)}
[ -x "$bin" ] && [ -f "$big" ] || { echo "FAIL setup: $bin or $big missing"; exit 1; }
cat > "$w/job.sh" <<'EOS'
#!/usr/bin/env bash
# job.sh BIN REPS W NAME IN_COLOR: every op once on the CPU and once on the GPU, TIME lines (ms) and a byte comparison
set -euo pipefail
bin=$1 reps=$2 w=$3 nm=$4 col=$5
t() { "$bin" "$@" reps="$reps" | awk '/^TIME/ { print $2 }'; }
"$bin" cvtColor "$w/$nm.gray.mcv" "$col" code=bgr2gray > /dev/null
gray=$w/$nm.gray.mcv
read -r rows cols <<< "$(od -An -tu4 -j4 -N8 "$col")"
cw=$(( cols / 2 )); ch=$(( rows / 2 ))
row() {  # name op in k=v...
  local label=$1 op=$2 in=$3; shift 3
  local c g
  c=$(t "$op" "$w/$nm.$label.cpu" "$in" "$@")
  g=$(t "$op" "$w/$nm.$label.gpu" "$in" "$@" gpu=1)
  cmp -s "$w/$nm.$label.cpu" "$w/$nm.$label.gpu" && same=yes || same=NO
  printf '| %s | %s | %.3f | %.3f | %.1f | %s |\n' "$nm $label" "$(basename "$in")" "$c" "$g" "$(awk -v c="$c" -v g="$g" 'BEGIN { printf "%f", c / g }')" "$same"
}
row cvtColor-gray cvtColor "$col" code=bgr2gray
row boxDown-f4 boxDown "$gray" f=4
row sharpness sharpness "$gray"
row Sobel-dx Sobel "$gray" dx=1 dy=0 ksize=3
row crop-quarter crop "$col" x=$(( cols / 4 )) y=$(( rows / 4 )) w=$cw h=$ch
EOS
chmod +x "$w/job.sh"
{
  echo "| op | input | CPU ms | GPU ms (with copies) | CPU / GPU | same bytes |"
  echo "|---|---|---|---|---|---|"
  gw cv-gpu-bench bash "$w/job.sh" "$bin" "$reps" "$w" hd tests/fixtures/hd.mcv 2>"$w/err.log"
  gw cv-gpu-bench-big bash "$w/job.sh" "$bin" "$reps" "$w" big "$big" 2>>"$w/err.log"
} | tee .work/bench_gpu.md
