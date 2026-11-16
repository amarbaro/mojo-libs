#!/usr/bin/env bash
# siglip-embed.sh [-j SHARDS] [-d DECODERS] LIST.txt OUTDIR: SigLIP image_embeds of every picture in LIST (one path per line) on the CPU runner.
# OUTDIR/embeds.f32 = 768 float32 per list line, in order. A picture that cannot be decoded gets a grey 224x224 stand-in and its line in
# OUTDIR/decode-failed.txt (its row is noise: drop it when scoring). Resumable: rerun with the same arguments, finished rows are kept.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
shards=2 dec=8
while [ $# -gt 0 ]; do case $1 in -j) shards=$2; shift 2;; -d) dec=$2; shift 2;; *) break;; esac; done
[ $# -eq 2 ] || { echo "FAIL usage: siglip-embed.sh [-j SHARDS] [-d DECODERS] LIST.txt OUTDIR" >&2; exit 2; }
list=$(realpath -- "$1"); out=$(realpath -m -- "$2"); mkdir -p "$out/ppm"
model=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}
[ -x "$root/.bin/mcv-labels" ] && [ -f "$model" ] || { echo "FAIL setup: .bin/mcv-labels (scripts/build-labels.sh) or $model missing" >&2; exit 1; }
n=$(wc -l < "$list"); [ "$n" -gt 0 ] || { echo "FAIL input: empty list" >&2; exit 1; }
nl -ba -w6 -nrz "$list" | awk -v o="$out/ppm" '{ s=$0; sub(/^[0-9]+\t/, "", s); printf "%s\t%s/%06d.ppm\n", s, o, $1 }' > "$out/pairs.tsv"
cut -f2 "$out/pairs.tsv" > "$out/ppms.txt"
dec1() { IFS=$'\t' read -r src dst <<< "$1"; [ -s "$dst" ] && return 0; "$2/scripts/decode-siglip.sh" "$src" "$dst.tmp" 2>/dev/null && mv "$dst.tmp" "$dst" \
  || { rm -f "$dst.tmp"; printf 'P6\n224 224\n255\n' > "$dst"; head -c 150528 /dev/zero | tr '\0' '\200' >> "$dst"; echo "$src" >> "$3/decode-failed.txt"; }; }
export -f dec1
: > "$out/decode-failed.txt"
tr '\n' '\0' < "$out/pairs.tsv" | xargs -0 -P "$dec" -I{} bash -c 'dec1 "$1" "$2" "$3"' _ {} "$root" "$out"
echo "decoded $n pictures ($(wc -l < "$out/decode-failed.txt") failed)"
per=$(( (n + shards - 1) / shards ))
split -l "$per" -d -a 2 "$out/ppms.txt" "$out/shard."
pids=()
for s in "$out"/shard.??; do nice -n 10 "$root/.bin/mcv-labels" image "$model" "$s" "$s.f32" > "$s.log" 2>&1 & pids+=($!); done
bad=0; for p in "${pids[@]}"; do wait "$p" || bad=1; done
[ "$bad" = 0 ] || { echo "FAIL embed: a shard failed, see $out/shard.*.log" >&2; exit 1; }
cat "$out"/shard.??.f32 > "$out/embeds.f32"
rows=$(( $(stat -c %s "$out/embeds.f32") / 3072 ))
[ "$rows" -eq "$n" ] || { echo "FAIL count: $rows embeddings for $n pictures" >&2; exit 1; }
echo "PASS siglip-embed: $n pictures -> $out/embeds.f32"
