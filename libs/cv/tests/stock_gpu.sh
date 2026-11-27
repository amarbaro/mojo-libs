#!/usr/bin/env bash
# tests/stock_gpu.sh [SET.txt] [ROUNDS]: the gates of `stockBatch gpu=1` (src/mojocv/gpustock.mojo), run inside one GPU job:
#   1 parity: `jpegBgr gpu=1` (planes from tj3DecompressToYUVPlanes8, upsample + colour on the card) equals tj3Decompress8 byte for
#     byte on the 20-file corpus and on planted JPEGs (4:2:0, 4:2:2, 4:4:4, grey, odd sizes, progressive, tiny)
#   2 lines: mcv-stockcheck gpu=1 writes the same bytes as the CPU path on SET (default the 406-image A/B set) and the plants
#   3 time: end-to-end wall of both arms on SET, interleaved, ROUNDS rounds (default 3)
# Call it as: gpu-wait run --timeout 1200 --mem 16 --priority 30 --label cv-stock-gpu -- tests/stock_gpu.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set_=${1:-$HOME/Projects/mojo/mojo-libs/libs/cv/.work/ab-jpeg/set.txt}
rounds=${2:-3}
corpus=${STOCK_GPU_CORPUS:-$HOME/Projects/AssetsHQ/.work/jpgbench/list.txt}
bin=.bin/mojo-cv
[ -x "$bin" ] || { echo "FAIL setup: $bin missing"; exit 1; }
w=.work/stock_gpu; rm -rf "$w"; mkdir -p "$w/plant"
src=tests/fixtures/stock/hd.png
p=$w/plant
magick "$src" -quality 90 -sampling-factor 2x2 "$p/s420.jpg"
magick "$src" -quality 90 -sampling-factor 2x1 "$p/s422.jpg"
magick "$src" -quality 90 -sampling-factor 1x1 "$p/s444.jpg"
magick "$src" -quality 90 -colorspace Gray "$p/grey.jpg"
magick "$src" -crop 1001x667+3+5 +repage -quality 85 -sampling-factor 2x2 "$p/odd420.jpg"
magick "$src" -crop 999x601+7+2 +repage -quality 85 -sampling-factor 2x1 "$p/odd422.jpg"
magick "$src" -crop 1203x905+1+1 +repage -quality 80 -interlace JPEG -sampling-factor 2x2 "$p/prog420.jpg"
magick "$src" -resize 37x23! -quality 90 -sampling-factor 2x2 "$p/tiny420.jpg"
magick "$src" -quality 90 -sampling-factor 1x2 "$p/s440.jpg"   # not a GPU sampling: the CPU path in gate 2, skipped in gate 1
# gate 1
n=0; bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case $f in *s440.jpg) continue;; esac
  n=$((n + 1))
  "$bin" jpegBgr "$w/a.mcv" "$f" > /dev/null
  "$bin" jpegBgr "$w/b.mcv" "$f" gpu=1 > "$w/b.log" || { cat "$w/b.log"; echo "FAIL parity: jpegBgr gpu=1 died on $f"; exit 1; }
  grep -q '^GPU-ARM jpegBgr' "$w/b.log" || { echo "FAIL parity: no GPU-ARM line for $f"; exit 1; }
  if ! cmp -s "$w/a.mcv" "$w/b.mcv"; then bad=$((bad + 1)); echo "DIFF parity $(basename "$f") $(cat "$w/b.log") $(cmp -l "$w/a.mcv" "$w/b.mcv" | wc -l) bytes"; fi
done < <(cat "$corpus"; ls "$p"/*.jpg)
[ "$bad" = 0 ] || { echo "FAIL parity: $bad of $n JPEGs differ from tj3Decompress8"; exit 1; }
echo "PASS parity: $n of $n JPEGs, BGR bytes of jpegBgr gpu=1 equal tj3Decompress8"
# gates 2 and 3: interleaved arms on the same files; each round's outputs are compared
cat "$set_" > "$w/set.txt"; ls "$p"/*.jpg >> "$w/set.txt"
for r in $(seq 1 "$rounds"); do
  order="cpu gpu"; [ $((r % 2)) = 0 ] && order="gpu cpu"
  for arm in $order; do
    opt=(); [ "$arm" = gpu ] && opt=(gpu=1)
    t0=$(date +%s.%N)
    scripts/mcv-stockcheck -j 14 "$w/$arm.$r.jsonl" @"$w/set.txt" "${opt[@]}" > "$w/$arm.$r.log" 2>&1 || { cat "$w/$arm.$r.log"; echo "FAIL run: $arm round $r"; exit 1; }
    t1=$(date +%s.%N)
    echo "TIME round $r $arm $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}') s load $(cut -d" " -f1 /proc/loadavg)"
  done
  if ! cmp -s "$w/cpu.$r.jsonl" "$w/gpu.$r.jsonl"; then
    diff <(jq -c . "$w/cpu.$r.jsonl") <(jq -c . "$w/gpu.$r.jsonl") | head -6
    echo "FAIL lines: round $r gpu=1 output differs from the CPU path"; exit 1
  fi
  echo "PASS lines: round $r, $(wc -l < "$w/gpu.$r.jsonl") lines byte-identical"
done
echo "PASS stock_gpu"
