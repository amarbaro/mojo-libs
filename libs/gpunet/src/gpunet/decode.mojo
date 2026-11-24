"""Anchor-point detector head for the zoo (plan R5a): the nine outputs of an SCRFD-family graph (scores, boxes, landmarks at strides
8, 16, 32 with 2 anchors per cell) to boxes in source pixels, then greedy NMS. Independent of faces: a letterbox is the caller's, its
`scale` (blob pixels per source pixel) is the one number this head needs. Decode and NMS follow insightface 0.7's SCRFD.detect."""
from std.collections import Dict
from gpunet.nn import Arr


struct Det(Copyable, Movable):
    var box: List[Float32]  # x1 y1 x2 y2, source pixels
    var score: Float32
    var kps: List[Float32]  # 5 points x, y

    def __init__(out self):
        self.box = List[Float32](length=4, fill=0.0)
        self.score = 0.0
        self.kps = List[Float32](length=10, fill=0.0)


def decode_scrfd(v: Dict[String, Arr], outputs: List[String], scale: Float32, thresh: Float32 = 0.5, nms_thresh: Float32 = 0.4, size: Int = 640) raises -> List[Det]:
    """Detections from the 9 outputs: names 0..2 scores, 3..5 box distances, 6..8 landmark offsets, one triple entry per stride."""
    var dets = List[Det]()
    var strides: List[Int] = [8, 16, 32]
    for s in range(3):
        var st = strides[s]
        ref sc = v[outputs[s]].d
        ref bb = v[outputs[s + 3]].d
        ref kp = v[outputs[s + 6]].d
        var gw = size // st
        for i in range(len(sc)):
            if sc[i] < thresh:
                continue
            var cell = i // 2
            var cx = Float32((cell % gw) * st)
            var cy = Float32((cell // gw) * st)
            var f = Det()
            f.score = sc[i]
            f.box[0] = (cx - bb[i * 4] * Float32(st)) / scale
            f.box[1] = (cy - bb[i * 4 + 1] * Float32(st)) / scale
            f.box[2] = (cx + bb[i * 4 + 2] * Float32(st)) / scale
            f.box[3] = (cy + bb[i * 4 + 3] * Float32(st)) / scale
            for k in range(5):
                f.kps[2 * k] = (cx + kp[i * 10 + 2 * k] * Float32(st)) / scale
                f.kps[2 * k + 1] = (cy + kp[i * 10 + 2 * k + 1] * Float32(st)) / scale
            dets.append(f^)
    return nms(dets^, nms_thresh)


def nms(var dets: List[Det], thresh: Float32) -> List[Det]:
    """Greedy NMS in stable descending score order, +1 pixel areas, drop overlap above `thresh`."""
    var n = len(dets)
    var order = List[Int]()
    for i in range(n):
        order.append(i)
    for i in range(1, n):
        var j = i
        while j > 0 and dets[order[j - 1]].score < dets[order[j]].score:
            order.swap_elements(j - 1, j)
            j -= 1
    var dead = List[Bool](length=n, fill=False)
    var keep = List[Det]()
    for a in range(n):
        var i = order[a]
        if dead[i]:
            continue
        keep.append(dets[i].copy())
        ref bi = dets[i].box
        var ai = (bi[2] - bi[0] + 1) * (bi[3] - bi[1] + 1)
        for b in range(a + 1, n):
            var j = order[b]
            if dead[j]:
                continue
            ref bj = dets[j].box
            var w = max(Float32(0), min(bi[2], bj[2]) - max(bi[0], bj[0]) + 1)
            var h = max(Float32(0), min(bi[3], bj[3]) - max(bi[1], bj[1]) + 1)
            var inter = w * h
            var aj = (bj[2] - bj[0] + 1) * (bj[3] - bj[1] + 1)
            if inter / (ai + aj - inter) > thresh:
                dead[j] = True
    return keep^
