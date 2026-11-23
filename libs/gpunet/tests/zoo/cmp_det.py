"""cmp_det.py GPUDIR REFDIR N ARM: GpuNet detector outputs and decoded boxes (zoo_det) against the onnxruntime oracle (oracle_det.py).
ARM 32 gates R5: boxes IoU >= 0.999 and scores within 1e-3 of the oracle's, same count of detections per image, raw outputs cosine >= 0.99999
(G0.8 fp32). ARM 16 gates the raw outputs at cosine >= 0.9995 (G0.8 fp16) and reports the box agreement without a threshold."""
import sys, numpy as np
g, r, n, arm = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
LEN = [12800, 3200, 800] + [4 * x for x in (12800, 3200, 800)] + [10 * x for x in (12800, 3200, 800)]
tc = 0.99999 if arm == "32" else 0.9995
def iou(a, b):
    w = max(0.0, min(a[2], b[2]) - max(a[0], b[0])); h = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    i = w * h; return i / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i)
def dets(p):
    t = open(p).read().split("\n")[:-1]; return [[float(x) for x in l.split("\t")] for l in t]
bad = 0; lo_cos = 1.0; max_abs = 0.0; lo_iou = 1.0; max_ds = 0.0; nref = ngpu = nmatch = 0
for i in range(n):
    t = f"{i:02d}"; a = np.fromfile(f"{g}/{t}.raw.f32", np.float32).astype(np.float64); b = np.fromfile(f"{r}/{t}.raw.f32", np.float32).astype(np.float64)
    if a.shape != b.shape or a.size != sum(LEN): print(f"FAIL shape: image {t} gpu {a.size} ref {b.size}"); bad += 1; continue
    o = 0
    for k, L in enumerate(LEN):
        x, y = a[o:o + L], b[o:o + L]; o += L
        c = float(x @ y / (np.linalg.norm(x) * np.linalg.norm(y)))
        lo_cos = min(lo_cos, c); max_abs = max(max_abs, float(np.abs(x - y).max()))
        if c < tc: bad += 1; print(f"FAIL raw: image {t} output {k} cosine {c:.7f} < {tc}")
    dg, dr = dets(f"{g}/{t}.det.tsv"), dets(f"{r}/{t}.det.tsv"); nref += len(dr); ngpu += len(dg); used = set()
    for q in dr:
        best, bj = 0.0, -1
        for j, p in enumerate(dg):
            if j not in used and iou(q[1:5], p[1:5]) > best: best, bj = iou(q[1:5], p[1:5]), j
        if bj >= 0: used.add(bj); lo_iou = min(lo_iou, best); max_ds = max(max_ds, abs(q[0] - dg[bj][0])); nmatch += 1
    if arm == "32" and len(dg) != len(dr): bad += 1; print(f"FAIL count: image {t} gpu {len(dg)} ref {len(dr)}")
print(f"arm {arm}: {n} images, raw outputs cosine min {lo_cos:.9f} max abs {max_abs:.2e}; detections ref {nref} gpu {ngpu} matched {nmatch}, box IoU min {lo_iou:.6f}, score diff max {max_ds:.2e}")
if arm == "32":
    if nmatch != nref or lo_iou < 0.999 or max_ds > 1e-3: bad += 1; print("FAIL boxes: IoU below 0.999, score off by more than 1e-3, or unmatched")
    if nref == 0: bad += 1; print("FAIL oracle: no detections, the check would pass on empty output")
print(f"FAIL cmp_det arm {arm}: {bad} checks" if bad else f"PASS cmp_det arm {arm}"); sys.exit(1 if bad else 0)
