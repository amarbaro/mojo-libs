#!/usr/bin/env bash
# SigLIP ranking gate: `mcv-labels top` (cosine, learned logit scale and bias, sigmoid) against numpy on the same embedding files:
# the top-5 label indices per picture equal, cosine within 1e-6, probability within 1e-5. Inputs: 40 library embeddings
# (.work/cvint/siglip40, from scripts/siglip-embed.sh) and the 160 label embeddings of data/siglip (`mcv-labels text`).
# Planted: the same ranking with a reversed label order must differ from the reference in at least half the pictures.
# Usage: tests/siglip_top.sh [BIN]   (BIN default .bin/mcv-labels; MODEL=onnx/model.onnx)
set -euo pipefail
cd "$(dirname "$0")/.."
W=.work/siglip; L=.work/cvint/labels; BIN=${1:-.bin/mcv-labels}
MODEL=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}
for f in .work/cvint/siglip40/embeds.f32 $L/all.f32 "$BIN" "$MODEL"; do [ -f "$f" ] || { echo "FAIL input: $f missing"; exit 1; }; done
"$BIN" top "$MODEL" .work/cvint/siglip40/embeds.f32 $L/all.f32 5 $W/top.tsv
uv run -q --no-project --with onnx --with numpy python -I - "$MODEL" .work/cvint/siglip40/embeds.f32 $L/all.f32 $W/top.tsv <<'EOF2' 2>/dev/null
import sys, numpy as np, onnx
from onnx import numpy_helper
model, imf, txf, tsv = sys.argv[1:5]
init = {t.name: numpy_helper.to_array(t) for t in onnx.load(model, load_external_data=False).graph.initializer}
scale, bias = float(np.exp(init["onnx::Exp_3336"].ravel()[0])), float(init["onnx::Add_3337"].ravel()[0])
im = np.fromfile(imf, np.float32).reshape(-1, 768).astype(np.float64); tx = np.fromfile(txf, np.float32).reshape(-1, 768).astype(np.float64)
cos = im @ tx.T
rows = [l.rstrip("\n").split("\t")[:-1] for l in open(tsv)]
bad = 0
for i, r in enumerate(rows):
    order = np.argsort(-cos[i])[:5]
    got = [x.split(":") for x in r]
    if [int(g[0]) for g in got] != list(order): bad += 1; continue
    for g, j in zip(got, order):
        p = 1 / (1 + np.exp(-(scale * cos[i, j] + bias)))
        if abs(float(g[1]) - cos[i, j]) > 1e-6 or abs(float(g[2]) - p) > 1e-5: bad += 1; break
planted = sum(1 for i in range(len(rows)) if [int(x.split(":")[0]) for x in rows[i]] != list(np.argsort(-cos[i, ::-1])[:5]))
print("FAIL top: %d of %d pictures differ from numpy" % (bad, len(rows)) if bad else ("FAIL plant: reversed order differs on %d of %d" % (planted, len(rows)) if planted * 2 < len(rows) else "PASS siglip_top: %d pictures, top-5 equal numpy (planted reversal differs on %d)" % (len(rows), planted)))
sys.exit(1 if bad or planted * 2 < len(rows) else 0)
EOF2
