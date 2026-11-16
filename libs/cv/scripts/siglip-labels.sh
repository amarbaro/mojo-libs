#!/usr/bin/env bash
# siglip-labels.sh LIST.txt EMBEDS.f32 [DECODE_FAILED.txt]: zero-shot labels of the pictures of LIST (row i of EMBEDS = line i) from the
# 18 categories and the tags of data/siglip: writes <picture>.labels.json beside each picture (LABELS_OUT_DIR=dir puts them there instead),
# {"cat_pred","cat_score" (cosine of the best category),"cats":[3 best],"tags":[top 5 with p >= 0.002],"top":[8 best tags with cosine and p],"model"}.
# The label embeddings are made once per tsv hash (mcv-labels text) under .work/siglip/. Predictions only: sidecars are never touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); cd "$root"
[ $# -ge 2 ] || { echo "FAIL usage: siglip-labels.sh LIST.txt EMBEDS.f32 [DECODE_FAILED.txt]" >&2; exit 2; }
list=$1; emb=$2; failed=${3:-/dev/null}
model=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; tok=${SIGLIP_TOK:-$HOME/Models/siglip-base-patch16-224-tok}
bin=${BIN:-.bin/mcv-labels}; W=.work/siglip; mkdir -p $W
n=$(wc -l < "$list"); rows=$(( $(stat -c %s "$emb") / 3072 ))
[ "$rows" -le "$n" ] && [ "$rows" -gt 0 ] || { echo "FAIL input: $rows embeddings for $n pictures" >&2; exit 1; }
h=$(cat data/siglip/categories.tsv data/siglip/tags.tsv | sha256sum | cut -c1-12); le=$W/labels.$h.f32
if [ ! -f "$le" ]; then
  jq -c '.normalizer.normalizers = [.normalizer.normalizers[4], .normalizer.normalizers[5]] | .model.byte_fallback = false' "$tok/tokenizer.json" > $W/tokenizer_pre.json
  cat <(cut -f2 data/siglip/categories.tsv) <(cut -f2 data/siglip/tags.tsv) > $W/labels.$h.txt
  "$bin" text "$model" $W/tokenizer_pre.json $W/labels.$h.txt "$le.tmp" && mv "$le.tmp" "$le"
fi
nc=$(wc -l < data/siglip/categories.tsv); nt=$(wc -l < data/siglip/tags.tsv)
head -c $((nc * 3072)) "$le" > $W/cat.$h.f32; tail -c +$((nc * 3072 + 1)) "$le" > $W/tag.$h.f32
head -c $((rows * 3072)) "$emb" > $W/emb.cut.f32
"$bin" top "$model" $W/emb.cut.f32 $W/cat.$h.f32 3 $W/top.cat.tsv
"$bin" top "$model" $W/emb.cut.f32 $W/tag.$h.f32 8 $W/top.tag.tsv
paste <(head -n "$rows" "$list") $W/top.cat.tsv $W/top.tag.tsv | awk -F'\t' -v cf=data/siglip/categories.tsv -v tf=data/siglip/tags.tsv -v fl="$failed" -v od="${LABELS_OUT_DIR:-}" '
  BEGIN { while ((getline l < cf) > 0) { split(l, a, "\t"); cn[c++] = a[1] } while ((getline l < tf) > 0) { split(l, a, "\t"); tn[t++] = a[1] } while ((getline l < fl) > 0) bad[l] = 1 }
  { p = $1; if (p in bad) next
    split($2, b, ":"); cats = ""
    for (k = 2; k <= 4; k++) { split($k, b, ":"); cats = cats (k > 2 ? "," : "") sprintf("{\"c\":\"%s\",\"cos\":%.4f}", cn[b[1]], b[2]) }
    split($2, b, ":"); pred = cn[b[1]]; sc = b[2]; top = ""; tags = ""; nt = 0
    for (k = 6; k <= 13; k++) { split($k, b, ":"); top = top (k > 6 ? "," : "") sprintf("{\"t\":\"%s\",\"cos\":%.4f,\"p\":%.4f}", tn[b[1]], b[2], b[3])
      if (nt < 5 && b[3] >= 0.002) { tags = tags (nt ? "," : "") "\"" tn[b[1]] "\""; nt++ } }
    f = p ".labels.json"; if (od != "") { m = split(p, q, "/"); f = od "/" q[m] ".labels.json" }
    printf "{\"cat_pred\":\"%s\",\"cat_score\":%.4f,\"cats\":[%s],\"tags\":[%s],\"top\":[%s],\"model\":\"siglip-base-patch16-224\"}\n", pred, sc, cats, tags, top > f; close(f) }'
echo "PASS siglip-labels: $rows pictures labelled"
