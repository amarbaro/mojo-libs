#!/usr/bin/env bash
# siglip-embed.sh [--cpu] [-j SHARDS] [-d DECODERS] LIST.txt OUTDIR: SigLIP image_embeds of every picture in LIST (one path per line).
# Default: GPU (mcv-labels gimage) under `gpu-wait run --timeout --mem MEM(8)`, HSA_OVERRIDE_GFX_VERSION dropped (it hides the card); --cpu = the CPU runner in SHARDS processes (default 2).
# OUTDIR/embeds.f32 = 768 float32 per list line, in order. A picture that cannot be decoded gets a grey 224x224 stand-in and its line in
# OUTDIR/decode-failed.txt (its row is noise: drop it when scoring). Resumable: rerun with the same arguments, finished rows are kept.
# Stall watchdog: no new embedding bytes for STALL seconds (default 60; STALL_FIRST=240 before the first write, model load) ->
# "STUCK" on stderr + notify-send, the job is killed, exit 3.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dev=gpu shards=2 dec=$(( $(nproc) - 2 ))
while [ $# -gt 0 ]; do case $1 in --cpu) dev=cpu; shift;; -j) shards=$2; shift 2;; -d) dec=$2; shift 2;; *) break;; esac; done
[ $# -eq 2 ] || { echo "FAIL usage: siglip-embed.sh [--cpu] [-j SHARDS] [-d DECODERS] LIST.txt OUTDIR" >&2; exit 2; }
list=$(realpath -- "$1"); out=$(realpath -m -- "$2"); mkdir -p "$out/ppm"
model=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; bin=$root/.bin/mcv-labels
[ -x "$bin" ] && [ -f "$model" ] || { echo "FAIL setup: $bin (scripts/build-labels.sh) or $model missing" >&2; exit 1; }
n=$(wc -l < "$list"); [ "$n" -gt 0 ] || { echo "FAIL input: empty list" >&2; exit 1; }

# decode: picture -> 224x224 P6, parallel on CPU
nl -ba -w6 -nrz "$list" | awk -v o="$out/ppm" '{ s=$0; sub(/^[0-9]+\t/, "", s); printf "%s\t%s/%06d.ppm\n", s, o, $1 }' > "$out/pairs.tsv"
cut -f2 "$out/pairs.tsv" > "$out/ppms.txt"
dec1() { IFS=$'\t' read -r src dst <<< "$1"; [ -s "$dst" ] && return 0; "$2/scripts/decode-siglip.sh" "$src" "$dst.tmp" 2>/dev/null && mv "$dst.tmp" "$dst" \
  || { rm -f "$dst.tmp"; printf 'P6\n224 224\n255\n' > "$dst"; head -c 150528 /dev/zero | tr '\0' '\200' >> "$dst"; echo "$src" >> "$3/decode-failed.txt"; }; }
export -f dec1
: > "$out/decode-failed.txt"
tr '\n' '\0' < "$out/pairs.tsv" | xargs -0 -P "$dec" -I{} bash -c 'dec1 "$1" "$2" "$3"' _ {} "$root" "$out"
echo "decoded $n pictures ($(wc -l < "$out/decode-failed.txt") failed)"

# embed
stuck() { echo "STUCK siglip-embed: $1" >&2; command -v notify-send >/dev/null && notify-send -u critical "siglip-embed STUCK" "$1" || true; }
watch() {  # watch PID FILES...: kill PID when the summed size of FILES stops growing
  local pid=$1 last=-1 since=$SECONDS lim=${STALL_FIRST:-240}; shift
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; local sz; sz=$(cat "$@" 2>/dev/null | wc -c)
    if [ "$sz" != "$last" ]; then [ "$last" -ge 0 ] && lim=${STALL:-60}; last=$sz; since=$SECONDS
    elif (( SECONDS - since > lim )); then stuck "no progress for ${lim}s at $(( sz / 3072 ))/$n rows"; kill -- "$pid" 2>/dev/null; return 3; fi
  done
}
if [ "$dev" = gpu ]; then
  gpu-wait run --timeout "${TIMEOUT:-1800}" --mem "${MEM:-8}" --label siglip-embed -- env -u HSA_OVERRIDE_GFX_VERSION "$bin" gimage "$model" "$out/ppms.txt" "$out/embeds.f32" > "$out/gpu.log" 2>&1 &
  job=$!; rc=0; watch "$job" "$out/embeds.f32" || rc=$?; [ "$rc" = 3 ] && exit 3
  wait "$job" || { echo "FAIL embed: gpu job, see $out/gpu.log" >&2; tail -5 "$out/gpu.log" >&2; exit 1; }
else
  per=$(( (n + shards - 1) / shards )); rm -f "$out"/shard.??; split -l "$per" -d -a 2 "$out/ppms.txt" "$out/shard."
  pids=(); for s in "$out"/shard.??; do nice -n 10 "$bin" image "$model" "$s" "$s.f32" > "$s.log" 2>&1 & pids+=($!); done
  for p in "${pids[@]}"; do watch "$p" "$out"/shard.??.f32 & done
  bad=0; for p in "${pids[@]}"; do wait "$p" || bad=1; done
  [ "$bad" = 0 ] || { echo "FAIL embed: a shard failed or stalled, see $out/shard.*.log" >&2; exit 1; }
  cat "$out"/shard.??.f32 > "$out/embeds.f32"
fi
rows=$(( $(stat -c %s "$out/embeds.f32") / 3072 ))
[ "$rows" -eq "$n" ] || { echo "FAIL count: $rows embeddings for $n pictures" >&2; exit 1; }
echo "PASS siglip-embed ($dev): $n pictures -> $out/embeds.f32"
