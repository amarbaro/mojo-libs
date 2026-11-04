"""Row driver for tests/cases/detection_*.txt (contract: tests/README.md).

Reads row lines (`op<TAB>args<TAB>expected`) on stdin, prints one JSON result per row. The same binary is
copied to build/detection_{converters,detections,iou,nms} by tests/build.sh.
"""

from std.ffi import external_call, c_ssize_t
from json import Json, parse, ARR
from supervision.detection.core import Detections
from supervision.detection.utils.converters import (
    mask_to_xyxy,
    xcycwh_to_xyxy,
    xywh_to_xyxy,
    xyxy_to_mask,
    xyxy_to_xcycarh,
    xyxy_to_xywh,
)
from supervision.detection.utils.iou_and_nms import (
    OVERLAP_IOU,
    box_iou,
    box_iou_batch,
    box_non_max_merge,
    box_non_max_suppression,
    mask_iou_batch,
    overlap_metric_from_value,
)


def flat_f(j: Json, mut out: List[Float64]):
    if j.kind() == ARR:
        for i in range(j.len()):
            flat_f(j.at(i), out)
    else:
        out.append(j.num())


def flat_i(j: Json, mut out: List[UInt8]):
    if j.kind() == ARR:
        for i in range(j.len()):
            flat_i(j.at(i), out)
    else:
        out.append(UInt8(j.int()))


def floats(j: Json) -> List[Float64]:
    var o = List[Float64]()
    flat_f(j, o)
    return o^


def metric(a: Json) raises -> Int:
    if a.has("overlap_metric"):
        return overlap_metric_from_value(a.get("overlap_metric").str())
    return OVERLAP_IOU


def jf(v: Float64) -> Json:
    return Json.of(v)


def jrow(v: List[Float64], start: Int, n: Int) -> Json:
    var r = Json.array()
    for i in range(start, start + n):
        r.push(jf(v[i]))
    return r^


def jflat(v: List[Float64]) -> Json:
    return jrow(v, 0, len(v))


def jmat(v: List[Float64], cols: Int) -> Json:
    var r = Json.array()
    if cols == 0:
        return r^
    for i in range(len(v) // cols):
        r.push(jrow(v, i * cols, cols))
    return r^


def jmat32(v: List[Float32], cols: Int) -> Json:
    var f = List[Float64]()
    for x in v:
        f.append(Float64(x))
    return jmat(f, cols)


def jints(v: List[Int]) -> Json:
    var r = Json.array()
    for x in v:
        r.push(Json.of(x))
    return r^


def jbools(v: List[Bool]) -> Json:
    var r = Json.array()
    for x in v:
        r.push(Json.of(x))
    return r^


def jmask3(m: List[UInt8], n: Int, h: Int, w: Int, as_bool: Bool) -> Json:
    var r = Json.array()
    for i in range(n):
        var plane = Json.array()
        for y in range(h):
            var row = Json.array()
            for x in range(w):
                var v = m[i * h * w + y * w + x] != 0
                row.push(Json.of(v) if as_bool else Json.of(Int(v)))
            plane.push(row^)
        r.push(plane^)
    return r^


def parse_masks(j: Json) -> Tuple[List[UInt8], Int, Int, Int]:
    """(flat, n, h, w) of an [n][h][w] nested list."""
    var m = List[UInt8]()
    flat_i(j, m)
    var n = j.len()
    var h = j.at(0).len() if n > 0 else 0
    var w = j.at(0).at(0).len() if h > 0 else 0
    return (m^, n, h, w)


def preds(j: Json) -> Tuple[List[Float64], List[Float64], List[Int]]:
    var xyxy = List[Float64]()
    var sc = List[Float64]()
    var cats = List[Int]()
    for i in range(j.len()):
        var r = j.at(i)
        for k in range(4):
            xyxy.append(r.at(k).num())
        sc.append(r.at(4).num())
        cats.append(Int(r.at(5).num()) if r.len() > 5 else 0)
    return (xyxy^, sc^, cats^)


def det_from(a: Json) raises -> Detections:
    var d = Detections(floats(a.get("xyxy")))
    if a.has("confidence"):
        d.set_confidence(floats(a.get("confidence")))
    d.validate()
    return d^


def det_json(d: Detections) -> Json:
    var o = Json.object()
    o.set("xyxy", jmat(d.xyxy, 4))
    if d.has_confidence:
        o.set("confidence", jflat(d.confidence))
    return o^


def run(op: String, a: Json) raises -> Json:
    if op == "box_iou":
        return jf(box_iou(floats(a.get("box_true")), floats(a.get("box_detection")), metric(a)))
    if op == "box_iou_batch":
        var t = floats(a.get("boxes_true"))
        var d = floats(a.get("boxes_detection"))
        return jmat32(box_iou_batch(t, d, metric(a)), len(d) // 4)
    if op == "mask_iou_batch":
        var t = parse_masks(a.get("masks_true"))
        var d = parse_masks(a.get("masks_detection"))
        var px = t[2] * t[3] if t[1] > 0 else d[2] * d[3]
        return jmat(mask_iou_batch(t[0], d[0], px, metric(a)), d[1])
    if op == "box_non_max_suppression":
        var p = preds(a.get("predictions"))
        return jbools(box_non_max_suppression(p[0], p[1], p[2], a.get("iou_threshold").num(), metric(a)))
    if op == "box_non_max_merge":
        var p = preds(a.get("predictions"))
        var groups = box_non_max_merge(p[0], p[1], p[2], a.get("iou_threshold").num(), metric(a))
        var r = Json.array()
        for g in groups:
            r.push(jints(g))
        return r^
    if op == "xywh_to_xyxy":
        return jmat(xywh_to_xyxy(floats(a.get("xywh"))), 4)
    if op == "xyxy_to_xywh":
        return jmat(xyxy_to_xywh(floats(a.get("xyxy"))), 4)
    if op == "xcycwh_to_xyxy":
        return jmat(xcycwh_to_xyxy(floats(a.get("xcycwh"))), 4)
    if op == "xyxy_to_xcycarh":
        return jmat(xyxy_to_xcycarh(floats(a.get("xyxy"))), 4)
    if op == "mask_to_xyxy":
        var m = parse_masks(a.get("masks"))
        var excl = a.has("coordinate_convention") and a.get("coordinate_convention").str() == "exclusive"
        var b = mask_to_xyxy(m[0], m[1], m[2], m[3], excl)
        var f = List[Float64]()
        for v in b:
            f.append(Float64(v))
        return jmat(f, 4)
    if op == "xyxy_to_mask":
        var res = a.get("resolution_wh")
        var w = res.at(0).int()
        var h = res.at(1).int()
        var boxes = floats(a.get("xyxy"))
        var excl = a.has("coordinate_convention") and a.get("coordinate_convention").str() == "exclusive"
        return jmask3(xyxy_to_mask(boxes, w, h, excl), len(boxes) // 4, h, w, True)
    if op == "detections_area":
        return jflat(det_from(a).area())
    if op == "detections_filter":
        var d = det_from(a)
        var keep = List[Bool]()
        for i in range(a.get("keep").len()):
            keep.append(a.get("keep").at(i).int() != 0)
        return det_json(d.select_where(keep))
    if op == "detections_merge":
        var parts = List[Detections]()
        var ps = a.get("parts")
        for i in range(ps.len()):
            parts.append(det_from(ps.at(i)))
        return det_json(Detections.merge(parts))
    raise Error("unknown op " + op)


def read_all_stdin() -> String:
    var buf = List[UInt8]()
    var chunk = List[UInt8](unsafe_uninit_length=65536)
    while True:
        var n = external_call["__read", c_ssize_t](0, chunk.unsafe_ptr(), 65536)
        if n <= 0:
            break
        for i in range(Int(n)):
            buf.append(chunk[i])
    return String(unsafe_from_utf8=buf)


def main() raises:
    var text = read_all_stdin()
    for line in text.split("\n"):
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        var result: Json
        try:
            result = run(String(cols[0]), parse(String(cols[1])))
        except e:
            result = Json.object()
            result.set("error", Json.of(String(e)))
        print(result.dumps())
