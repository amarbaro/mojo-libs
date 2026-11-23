#!/usr/bin/env bash
# tests/cases_gpu/cvint-rebuild.sh [DIR]: rebuild the frozen SigLIP inputs the P0 gate G0.10 found gone (`.work/cvint/*`, the 7593-picture run of
# the cvint lane, 2026-11-16, never kept). DIR defaults to .work/cvint under the cv root. The rebuilt set is a FROZEN SUBSET, not that run:
#   library-images.txt          every png, jpg and jpeg under AssetsHQ/library/images, sorted (siglip_img.sh samples 8 of them with a seeded shuf)
#   siglip40/embeds.f32         CPU embeddings of 40 of them (shuf, seed 40), the input of siglip_top.sh
#   labels/all.f32              text embeddings of the 18 categories and 142 tags of data/siglip (siglip_top.sh)
#   siglip-full/embeds.f32      CPU embeddings of N (default 240, a multiple of the 16-picture GPU batch) of them (shuf, seed 240), picture list in siglip-full/list.txt
#   siglip-gpu.f32              the GPU runner's embeddings of the same decoded 224 px pictures (one shared gpu-wait job)
#   MANIFEST.sha256, README     hashes of the above and what each is; a rerun with the same library list gives the same picks, the embeddings are
#                               rewritten (the CPU runner is deterministic on one machine; the siglip checks compare arms and numpy, not these bytes)
# JPEG and PNG decode stay on the CPU (scripts/decode-siglip.sh). No timing is claimed. Exit 0 PASS, 1 FAIL, 3 BLOCK (a missing precondition).
set -euo pipefail
cd "$(dirname "$0")/../.."
D=${1:-.work/cvint}; N=${N:-240}
LIB=${LIBRARY:-$HOME/Projects/AssetsHQ/library/images}
MODEL=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; TOK=${SIGLIP_TOK:-$HOME/Models/siglip-base-patch16-224-tok}
for f in "$LIB" "$MODEL" "$TOK/tokenizer.json" data/siglip/categories.tsv data/siglip/tags.tsv; do
  [ -e "$f" ] || { echo "BLOCK cvint-rebuild: $f missing"; exit 3; }
done
scripts/build-labels.sh
bin=.bin/mcv-labels; [ -x "$bin" ] || { echo "FAIL setup: $bin"; exit 1; }
mkdir -p "$D/labels" "$D/siglip40" "$D/siglip-full"
find "$LIB" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | LC_ALL=C sort > "$D/library-images.txt"
total=$(wc -l < "$D/library-images.txt"); [ "$total" -ge "$N" ] || { echo "BLOCK cvint-rebuild: only $total library pictures for N=$N"; exit 3; }
shuf -n 40 --random-source=<(yes 40) "$D/library-images.txt" > "$D/siglip40/list.txt"
shuf -n "$N" --random-source=<(yes 240) "$D/library-images.txt" > "$D/siglip-full/list.txt"
# CPU rows (decode on the CPU, the CPU runner in 3 shards)
scripts/siglip-embed.sh --cpu -j 3 "$D/siglip40/list.txt" "$D/siglip40"
scripts/siglip-embed.sh --cpu -j 3 "$D/siglip-full/list.txt" "$D/siglip-full"
for d in siglip40 siglip-full; do
  [ ! -s "$D/$d/decode-failed.txt" ] || { echo "FAIL decode: $(wc -l < "$D/$d/decode-failed.txt") pictures of $d did not decode: see $D/$d/decode-failed.txt"; exit 1; }
done
# GPU rows of the same decoded pictures, one shared job
gpu-wait run --shared --vram 2 --timeout 300 --mem 8 --label cvint-gpu -- env -u HSA_OVERRIDE_GFX_VERSION "$bin" gimage "$MODEL" "$D/siglip-full/ppms.txt" "$D/siglip-gpu.f32" > "$D/siglip-gpu.log" 2>&1 \
  || { tail -5 "$D/siglip-gpu.log"; echo "FAIL gpu embeddings: see $D/siglip-gpu.log"; exit 1; }
# labels, the way scripts/siglip-labels.sh makes them
jq -c '.normalizer.normalizers = [.normalizer.normalizers[4], .normalizer.normalizers[5]] | .model.byte_fallback = false' "$TOK/tokenizer.json" > "$D/labels/tokenizer_pre.json"
cat <(cut -f2 data/siglip/categories.tsv) <(cut -f2 data/siglip/tags.tsv) > "$D/labels/texts.txt"
"$bin" text "$MODEL" "$D/labels/tokenizer_pre.json" "$D/labels/texts.txt" "$D/labels/all.f32"
for f in siglip40/embeds.f32 siglip-full/embeds.f32 siglip-gpu.f32 labels/all.f32; do
  [ -s "$D/$f" ] || { echo "FAIL output: $D/$f empty"; exit 1; }
done
[ $(( $(stat -c %s "$D/siglip40/embeds.f32") )) -eq $((40 * 3072)) ] || { echo "FAIL rows: siglip40"; exit 1; }
[ $(( $(stat -c %s "$D/siglip-full/embeds.f32") )) -eq $((N * 3072)) ] && [ "$(stat -c %s "$D/siglip-gpu.f32")" -eq $((N * 3072)) ] || { echo "FAIL rows: siglip-full or siglip-gpu not $N x 768 float32"; exit 1; }
[ "$(stat -c %s "$D/labels/all.f32")" -eq $((160 * 3072)) ] || { echo "FAIL rows: labels not 160 x 768 float32"; exit 1; }
( cd "$D" && sha256sum library-images.txt siglip40/list.txt siglip40/embeds.f32 siglip-full/list.txt siglip-full/embeds.f32 siglip-gpu.f32 labels/all.f32 > MANIFEST.sha256 )
cat > "$D/README" <<EOF
Rebuilt $(date +%F) by tests/cases_gpu/cvint-rebuild.sh (lane S2, full-stack P2). A frozen SUBSET: $N pictures for siglip-full and siglip-gpu, 40 for siglip40,
picked by seeded shuf from $total library pictures under $LIB. The original 7593-picture run of the cvint lane is gone. Hashes: MANIFEST.sha256.
EOF
echo "PASS cvint-rebuild: $total library pictures listed, siglip40 40 rows, siglip-full and siglip-gpu $N rows, labels 160 rows -> $D"
