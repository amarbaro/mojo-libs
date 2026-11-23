"""oracle_det.py MODEL LIST OUTDIR N: onnxruntime (CPU) oracle for an SCRFD-family detector on the first N JPEGs of LIST (JPEG decode on the CPU, PIL).
Writes OUTDIR/NN.blob.f32 (letterbox 640, (x-127.5)/128, RGB, CHW: the input of both runners), NN.raw.f32 (the nine outputs, graph order,
concatenated), NN.det.tsv (numpy decode and NMS of those outputs, blob pixels: score, box, five landmarks) and blobs.list."""
import sys, numpy as np, onnxruntime as ort
from PIL import Image, ImageOps
model, lst, out, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
S = 640; THR = 0.5; NMS = 0.4
paths = [l.strip() for l in open(lst) if l.strip()][:n]
sess = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
inp = sess.get_inputs()[0].name; names = [o.name for o in sess.get_outputs()]
assert len(names) == 9, names

def blob_of(p):
    im = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
    ratio = im.height / im.width
    nh, nw = (S, int(S / ratio)) if ratio > 1 else (int(S * ratio), S)
    r = np.asarray(im.resize((nw, nh), Image.BILINEAR), np.float32)
    b = np.full((S, S, 3), 0.0, np.float32); b[:nh, :nw] = r
    pad = np.zeros((S, S), bool); pad[nh:, :] = True; pad[:, nw:] = True
    x = (b - 127.5) / 128.0; x[pad] = (0.0 - 127.5) / 128.0
    return np.ascontiguousarray(x.transpose(2, 0, 1)[None])

def decode(o):
    dets = []
    for s, st in enumerate((8, 16, 32)):
        sc, bb, kp = o[s].reshape(-1), o[s + 3].reshape(-1, 4), o[s + 6].reshape(-1, 10)
        gw = S // st
        for i in np.nonzero(sc >= THR)[0]:
            c = i // 2; cx, cy = (c % gw) * st, (c // gw) * st
            box = [cx - bb[i, 0] * st, cy - bb[i, 1] * st, cx + bb[i, 2] * st, cy + bb[i, 3] * st]
            k = [(cx if j % 2 == 0 else cy) + kp[i, j] * st for j in range(10)]
            dets.append((float(sc[i]), box, k))
    order = sorted(range(len(dets)), key=lambda i: -dets[i][0])   # stable: sorted keeps input order on ties
    dead = set(); keep = []
    for a, i in enumerate(order):
        if i in dead: continue
        keep.append(dets[i]); bi = dets[i][1]; ai = (bi[2] - bi[0] + 1) * (bi[3] - bi[1] + 1)
        for j in order[a + 1:]:
            if j in dead: continue
            bj = dets[j][1]
            w = max(0.0, min(bi[2], bj[2]) - max(bi[0], bj[0]) + 1); h = max(0.0, min(bi[3], bj[3]) - max(bi[1], bj[1]) + 1)
            aj = (bj[2] - bj[0] + 1) * (bj[3] - bj[1] + 1)
            if w * h / (ai + aj - w * h) > NMS: dead.add(j)
    return keep

with open(f"{out}/blobs.list", "w") as bl:
    for idx, p in enumerate(paths):
        t = f"{idx:02d}"; b = blob_of(p); b.tofile(f"{out}/{t}.blob.f32"); bl.write(f"{out}/{t}.blob.f32\n")
        o = sess.run(names, {inp: b})
        np.concatenate([x.reshape(-1) for x in o]).astype(np.float32).tofile(f"{out}/{t}.raw.f32")
        with open(f"{out}/{t}.det.tsv", "w") as f:
            for sc, box, k in decode(o): f.write("\t".join(f"{v:.9g}" for v in [sc] + box + k) + "\n")
print("oracle_det:", len(paths), "images")
