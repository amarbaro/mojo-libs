#!/usr/bin/env bash
# GPU vs CPU embeddings of the same 224x224 pictures (scripts/siglip-embed.sh made the CPU rows, `mcv-labels gimage` the GPU rows):
# every row's cosine >= 0.99999 and max abs <= 1e-4, and the two files have the same row count. Planted: each GPU row against the
# next CPU row must fall under cosine 0.99 for at least 90 % of the rows (a constant or shifted output cannot pass).
# Usage: tests/siglip_gpu.sh [CPU.f32 GPU.f32]   defaults .work/cvint/siglip-full/embeds.f32 and .work/cvint/siglip-gpu.f32
set -euo pipefail
cd "$(dirname "$0")/.."
cpu=${1:-.work/cvint/siglip-full/embeds.f32}; gpu=${2:-.work/cvint/siglip-gpu.f32}
for f in "$cpu" "$gpu"; do [ -f "$f" ] || { echo "FAIL input: $f missing"; exit 1; }; done
uv run -q --no-project --with numpy python -I - "$cpu" "$gpu" <<'EOF2'
import sys, numpy as np
a = np.fromfile(sys.argv[1], np.float32).reshape(-1, 768).astype(np.float64)
b = np.fromfile(sys.argv[2], np.float32).reshape(-1, 768).astype(np.float64)
if len(a) != len(b): print(f"FAIL rows: cpu {len(a)} gpu {len(b)}"); sys.exit(1)
cos = (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1))
mx = np.abs(a - b).max(1)
bad = int(((cos < 0.99999) | (mx > 1e-4)).sum())
pl = int((((a * np.roll(b, -1, 0)).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(np.roll(b, -1, 0), axis=1))) < 0.99).sum())
print(f"rows {len(a)} cosine min {cos.min():.9f} mean {cos.mean():.9f} max abs diff max {mx.max():.2e} out of tolerance {bad} planted-below-0.99 {pl}")
if bad: print(f"FAIL parity: {bad} of {len(a)} rows out of tolerance"); sys.exit(1)
if pl < 0.9 * len(a): print("FAIL plant: shifted rows still agree, the gate would pass on an inert output"); sys.exit(1)
print(f"PASS siglip_gpu: {len(a)} pictures, GPU embeddings equal the CPU runner's (planted shift differs on {pl})")
EOF2
