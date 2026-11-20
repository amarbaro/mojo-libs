#!/usr/bin/env bash
# SigLIP text tower gate (CPU runner): text_embeds of mcv-labels for 12 texts (labels and odd strings) against onnxruntime on the same
# graph fed the ids of transformers' SiglipTokenizer: cosine >= 0.999999 and max abs <= 1e-5 per text.
# Planted: each embedding compared with the next text's reference must fall under cosine 0.99 (a constant or shifted output cannot pass).
# Usage: tests/siglip_text.sh   (MODEL=onnx/model.onnx of onnx-community/siglip-base-patch16-224-ONNX, SIGLIP_TOK=tokenizer dir)
set -euo pipefail
cd "$(dirname "$0")/.."
W=.work/siglip; mkdir -p $W
MODEL=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; TOK=${SIGLIP_TOK:-$HOME/Models/siglip-base-patch16-224-tok}
[ -f "$MODEL" ] || { echo "FAIL input: $MODEL missing"; exit 1; }
scripts/build-labels.sh
jq -c '.normalizer.normalizers = [.normalizer.normalizers[4], .normalizer.normalizers[5]] | .model.byte_fallback = false' "$TOK/tokenizer.json" > $W/tokenizer_pre.json
printf '%s\n' "a photo of a cat" "a photo of a dog." "a 3d render of a robot" "an icon for a user interface" "a picture of food on a plate" \
  "a photo of a person" "a photo of a vehicle" "a photo of a weapon" "science and medical imagery" "a seamless surface texture" \
  "ICONS-UI: Health & Wellness" "x" > $W/t12.txt
/usr/bin/time -f 'text tower %e s %M KB' .bin/mcv-labels text "$MODEL" $W/tokenizer_pre.json $W/t12.txt $W/t12.f32
uv run -q --no-project --with transformers --with sentencepiece --with protobuf --with onnxruntime --with numpy python -I - "$MODEL" "$TOK" $W <<'EOF2' 2>/dev/null
import sys, numpy as np, onnxruntime as ort
from transformers import SiglipTokenizer
model, tok, w = sys.argv[1:4]
t = SiglipTokenizer.from_pretrained(tok)
lines = open(f"{w}/t12.txt").read().split("\n")[:-1]
s = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
got = np.fromfile(f"{w}/t12.f32", np.float32).reshape(len(lines), -1)
ref = []
for x in lines:
    ids = np.array([t(x, padding="max_length", max_length=64, truncation=True)["input_ids"]], np.int64)
    out = s.run(["text_embeds"], {"input_ids": ids, "pixel_values": np.zeros((1, 3, 224, 224), np.float32)})[0][0]
    ref.append(out)
ref = np.array(ref, np.float32)
cos = lambda a, b: float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
bad = 0
for i, x in enumerate(lines):
    c, m = cos(got[i], ref[i]), float(np.abs(got[i] - ref[i]).max())
    p = cos(got[i], ref[(i + 1) % len(lines)])
    print(f"text {i} cos {c:.9f} maxabs {m:.2e} planted-cos {p:.4f}")
    if c < 0.999999 or m > 1e-5 or p > 0.99: bad += 1
print("FAIL text: %d of %d texts out of tolerance" % (bad, len(lines)) if bad else "PASS siglip_text: %d texts equal onnxruntime" % len(lines))
sys.exit(1 if bad else 0)
EOF2
