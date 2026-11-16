#!/usr/bin/env bash
# SigLIP vision path gate: 8 seeded library pictures (png, jpg, RGBA, grey included when present) through decode-siglip.sh + mcv-labels image
# against transformers' SiglipImageProcessor (PIL) + onnxruntime on the same graph: pixel max abs and embedding cosine per picture.
# Tolerances: pixel mean abs <= 0.005 and max <= 0.1 in the normalised scale (resampler rounding; a swapped channel or wrong kernel is far above), embedding cosine >= 0.999.
# Planted: each embedding against the next picture's reference must fall under cosine 0.99.
# Usage: tests/siglip_img.sh [LIST.txt of images]   (MODEL=onnx/model.onnx)
set -euo pipefail
cd "$(dirname "$0")/.."
W=.work/siglip; mkdir -p $W/img
MODEL=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; [ -f "$MODEL" ] || { echo "FAIL input: $MODEL missing"; exit 1; }
LIST=${1:-.work/cvint/library-images.txt}; [ -f "$LIST" ] || { echo "FAIL input: $LIST missing"; exit 1; }
scripts/build-labels.sh
shuf -n 8 --random-source=<(yes 7) "$LIST" > $W/img/src.txt
: > $W/img/ppm.txt; i=0
while IFS= read -r f; do i=$((i + 1)); scripts/decode-siglip.sh "$f" $W/img/$i.ppm; echo "$PWD/$W/img/$i.ppm" >> $W/img/ppm.txt; done < $W/img/src.txt
rm -f $W/img/got.f32
/usr/bin/time -f 'image tower, 8 pictures: %e s %M KB' .bin/mcv-labels image "$MODEL" $W/img/ppm.txt $W/img/got.f32
uv run -q --no-project --with transformers --with onnxruntime --with numpy --with pillow python -I - "$MODEL" $W/img <<'EOF2' 2>/dev/null
import sys, numpy as np, onnxruntime as ort
from PIL import Image
from transformers import SiglipImageProcessor
model, w = sys.argv[1:3]
proc = SiglipImageProcessor.from_pretrained("google/siglip-base-patch16-224") if False else SiglipImageProcessor(size={"height": 224, "width": 224}, resample=3, do_rescale=True, rescale_factor=1 / 255, do_normalize=True, image_mean=[0.5] * 3, image_std=[0.5] * 3)
srcs = open(f"{w}/src.txt").read().split("\n")[:-1]
s = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
got = np.fromfile(f"{w}/got.f32", np.float32).reshape(len(srcs), -1)
ref, bad = [], 0
cos = lambda a, b: float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
for i, f in enumerate(srcs):
    px = proc(Image.open(f).convert("RGB"), return_tensors="np")["pixel_values"].astype(np.float32)
    ppm = np.asarray(Image.open(f"{w}/{i + 1}.ppm").convert("RGB"), np.float32).transpose(2, 0, 1)[None] / 255
    mine = (ppm - 0.5) / 0.5
    ref.append(s.run(["image_embeds"], {"pixel_values": px, "input_ids": np.zeros((1, 64), np.int64)})[0][0])
    d, mu, c = float(np.abs(mine - px).max()), float(np.abs(mine - px).mean()), cos(got[i], ref[-1])
    print(f"pic {i} pixels max {d:.3f} mean {mu:.5f} cos {c:.6f}")
    if d > 0.1 or mu > 0.005 or c < 0.999: bad += 1
ref = np.array(ref)
for i in range(len(srcs)):
    p = cos(got[i], ref[(i + 1) % len(srcs)])
    if p > 0.99: print("plant: pic", i, "vs next cos", round(p, 4)); bad += 1
print("FAIL image: %d problems" % bad if bad else "PASS siglip_img: %d pictures, embeddings equal HF preprocess + onnxruntime" % len(srcs))
sys.exit(1 if bad else 0)
EOF2
