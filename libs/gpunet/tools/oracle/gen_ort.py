#!/usr/bin/env python3
"""CPU onnxruntime oracle for GpuNet parity rows.

Runs one ONNX model on seeded fixed inputs with CPUExecutionProvider only and writes each
output as .npy plus summary.tsv (output, dtype, shape, sha256 of the array bytes).
Usage: gen_ort.py MODEL.onnx OUTDIR det|arc|siglip
No GPU provider is requested. Inputs come from numpy RNG seed 0, not from images.
"""
import hashlib
import os
import sys

import numpy as np
import onnxruntime as ort

model, outdir, kind = sys.argv[1], sys.argv[2], sys.argv[3]
if kind not in ("det", "arc", "siglip"):
    raise SystemExit("FAIL args: kind must be det, arc or siglip")
os.makedirs(outdir, exist_ok=True)
rng = np.random.default_rng(0)

sess = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
feed = {}
for i in sess.get_inputs():
    if kind == "siglip" and i.name == "input_ids":
        feed[i.name] = rng.integers(0, 32000, (1, 64)).astype(np.int64)
    else:
        side = {"det": 640, "arc": 112, "siglip": 224}[kind]
        feed[i.name] = rng.uniform(-1.0, 1.0, (1, 3, side, side)).astype(np.float32)

outs = sess.run(None, feed)
rows = []
for o, arr in zip(sess.get_outputs(), outs):
    safe = o.name.replace("/", "_")
    np.save(os.path.join(outdir, safe + ".npy"), arr)
    digest = hashlib.sha256(np.ascontiguousarray(arr).tobytes()).hexdigest()
    rows.append(f"{safe}\t{arr.dtype}\t{'x'.join(map(str, arr.shape))}\t{digest}")
with open(os.path.join(outdir, "summary.tsv"), "w") as f:
    f.write("output\tdtype\tshape\tsha256_bytes\n" + "\n".join(rows) + "\n")
print("PASS oracle", os.path.basename(model), len(outs), "outputs", sess.get_providers())
