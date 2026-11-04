#!/usr/bin/env python3
"""Oracle rows for the detection tools (S4). Run: .work/oracle-venv/bin/python -I tools/gen_tools.py
Row: <op>\t<args JSON>\t<expected JSON>; line 1 = '# gen: tools/gen_tools.py seed=<n>'.
Errors: expected {"error": "<PythonExceptionName>"}."""
import json, os, random, sys

import numpy as np

import warnings

from supervision import Detections, Point, Position
from supervision.detection.line_zone import LineZone
from supervision.detection.tools.csv_sink import CSVSink
from supervision.detection.tools.inference_slicer import InferenceSlicer
from supervision.detection.tools.json_sink import JSONSink

warnings.simplefilter("ignore")

SEED = 4
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "cases")


def dump(x):
    return json.dumps(x, separators=(",", ":"), allow_nan=False)


def write(name, rows):
    path = os.path.join(OUT, f"{name}.txt")
    with open(path, "w") as f:
        f.write(f"# gen: tools/gen_tools.py seed={SEED}\n")
        for op, args, exp in rows:
            f.write(f"{op}\t{dump(args)}\t{dump(exp)}\n")
    print(f"{name}: {len(rows)} rows")


def tup(v):
    return [int(v[0]), int(v[1])]


def slicer_rows(rng):
    rows = []

    def add(image, sl, ov):
        args = {"image_wh": image, "slice_wh": sl, "overlap_wh": ov}
        try:
            s = InferenceSlicer(callback=lambda x: None, slice_wh=tuple(sl), overlap_wh=tuple(ov))
            off = InferenceSlicer._generate_offset(tuple(image), s.slice_wh, s.overlap_wh)
            rows.append(("slicer_offsets", args, [[int(v) for v in r] for r in off]))
        except ValueError:
            rows.append(("slicer_offsets", args, {"error": "ValueError"}))

    # hand-picked edges: smaller image, exact fit, zero overlap, overlap >= slice, last tile flush
    for image, sl, ov in [
        ([1000, 700], [640, 640], [100, 100]), ([100, 100], [640, 640], [100, 100]),
        ([640, 640], [640, 640], [0, 0]), ([641, 641], [640, 640], [0, 0]),
        ([1280, 640], [640, 640], [0, 0]), ([1280, 640], [640, 640], [639, 0]),
        ([640, 640], [640, 640], [640, 0]), ([640, 640], [640, 640], [0, 640]),
        ([1, 1], [1, 1], [0, 0]), ([5, 3], [2, 2], [1, 1]), ([7, 7], [3, 3], [2, 2]),
        ([1920, 1080], [640, 640], [128, 128]), ([1920, 1080], [960, 540], [0, 0]),
        ([10, 10], [4, 6], [3, 5]),
    ]:
        add(image, sl, ov)
    for _ in range(140):
        sw, sh = rng.randint(1, 64), rng.randint(1, 64)
        ow = rng.randint(0, sw - 1) if rng.random() < 0.95 else rng.randint(sw, sw + 3)
        oh = rng.randint(0, sh - 1) if rng.random() < 0.95 else rng.randint(sh, sh + 3)
        add([rng.randint(1, 200), rng.randint(1, 200)], [sw, sh], [ow, oh])
    for bad in ([0, 5], [5, 0], [-1, 5]):
        add([20, 20], bad, [0, 0])
    add([20, 20], [5, 5], [-1, 0])
    return rows


ALL_ANCHORS = ["TOP_LEFT", "TOP_RIGHT", "BOTTOM_LEFT", "BOTTOM_RIGHT"]
ANCHOR_POOL = ["CENTER", "CENTER_LEFT", "CENTER_RIGHT", "TOP_CENTER", "TOP_LEFT", "TOP_RIGHT",
               "BOTTOM_LEFT", "BOTTOM_CENTER", "BOTTOM_RIGHT"]


def per_class(counter):
    return [[None if k is None else int(k), int(v)] for k, v in counter.items()]


def line_case(rng, frames, start, end, anchors, thr):
    args = {"start": start, "end": end, "anchors": anchors, "min_threshold": thr, "frames": frames}
    try:
        z = LineZone(Point(*start), Point(*end), triggering_anchors=[Position[a] for a in anchors],
                     minimum_crossing_threshold=thr)
    except ValueError:
        return ("line_zone", args, {"error": "ValueError"})
    out = []
    for f in frames:
        xyxy = np.array(f["xyxy"], dtype=float).reshape(-1, 4)
        d = Detections(xyxy=xyxy,
                       tracker_id=None if f["tracker_id"] is None else np.array(f["tracker_id"], dtype=int),
                       class_id=None if f["class_id"] is None else np.array(f["class_id"], dtype=int))
        ci, co = z.trigger(d)
        out.append({"in": [bool(v) for v in ci], "out": [bool(v) for v in co]})
    out.append({"in_count": int(z.in_count), "out_count": int(z.out_count),
                "in_per_class": per_class(z._in_count_per_class),
                "out_per_class": per_class(z._out_count_per_class)})
    return ("line_zone", args, out)


def line_rows(rng):
    rows = []
    for k in range(70):
        start = [float(rng.randint(0, 100)), float(rng.randint(0, 100))]
        end = [float(rng.randint(0, 100)), float(rng.randint(0, 100))]
        if k == 0:
            end = list(start)  # zero magnitude -> error
        anchors = ALL_ANCHORS if rng.random() < 0.4 else rng.sample(ANCHOR_POOL, rng.randint(1, 3))
        thr = rng.choice([0, 1, 1, 2, 3])
        ntr = rng.randint(1, 5)
        cx, cy = (start[0] + end[0]) / 2, (start[1] + end[1]) / 2
        pos = {t: [cx + rng.uniform(-40, 40), cy + rng.uniform(-40, 40)] for t in range(ntr)}
        # aim each track at a point near the line centre so most of them cross it
        vel = {t: [(cx + rng.uniform(-8, 8) - pos[t][0]) / 8 * rng.uniform(0.6, 1.4),
                   (cy + rng.uniform(-8, 8) - pos[t][1]) / 8 * rng.uniform(0.6, 1.4)] for t in range(ntr)}
        cls = {t: rng.randint(0, 2) for t in range(ntr)}
        use_cls = rng.random() < 0.7
        frames = []
        for fi in range(rng.randint(1, 30) if k % 5 else 30):
            ids = [t for t in range(ntr) if rng.random() < 0.85]
            xyxy, tids = [], []
            for t in ids:
                pos[t][0] += vel[t][0]; pos[t][1] += vel[t][1]
                w, h = rng.uniform(2, 20), rng.uniform(2, 20)
                xyxy.append([pos[t][0] - w / 2, pos[t][1] - h / 2, pos[t][0] + w / 2, pos[t][1] + h / 2])
                tids.append(-1 if rng.random() < 0.05 else t)
            no_tracker = rng.random() < 0.05
            frames.append({"xyxy": xyxy, "tracker_id": None if no_tracker else tids,
                           "class_id": [cls[t] for t in ids] if use_cls else None})
        rows.append(line_case(rng, frames, start, end, anchors, thr))
    return rows


WORDS = ["a", "cat", "x y", "a,b", 'say "hi"', "line\nbreak", "tab\tsep", "caf\u00e9", "", " pad "]


def py_value(v):
    """Args encoding -> Python: {"nd": [...]} ndarray, bare array list, else scalar."""
    if isinstance(v, dict):
        return np.array(v["nd"])
    return v


def sink_append(rng, n):
    a = {"xyxy": [[round(rng.uniform(0, 50), 3) for _ in range(4)] for _ in range(n)]}
    a["class_id"] = [rng.randint(0, 5) for _ in range(n)] if rng.random() < 0.7 else None
    a["confidence"] = [round(rng.uniform(0, 1), 4) for _ in range(n)] if rng.random() < 0.7 else None
    a["tracker_id"] = [rng.randint(0, 9) for _ in range(n)] if rng.random() < 0.5 else None
    data = {}
    for key in rng.sample(["class_name", "score2", "emb", "note"], rng.randint(0, 3)):
        if key == "class_name" or key == "note":
            data[key] = {"nd": [rng.choice(WORDS) for _ in range(n)]}
        elif key == "emb":
            data[key] = {"nd": [[round(rng.uniform(0, 9), 2) for _ in range(3)] for _ in range(n)]}
        else:
            data[key] = {"nd": [round(rng.uniform(0, 9), 3) for _ in range(n)]}
    a["data"] = data
    custom = {}
    for key in rng.sample(["frame", "src", "tag", "ids", "names", "extra", "flag", "score2"], rng.randint(0, 4)):
        kind = rng.choice(["int", "float", "str", "bool", "list", "ndn", "ndother"])
        if kind == "int": custom[key] = rng.randint(-5, 500)
        elif kind == "float": custom[key] = round(rng.uniform(-9, 9), 3)
        elif kind == "str": custom[key] = rng.choice(WORDS)
        elif kind == "bool": custom[key] = rng.random() < 0.5
        elif kind == "list": custom[key] = [rng.randint(0, 99) for _ in range(n)]
        elif kind == "ndn": custom[key] = {"nd": [rng.choice(WORDS) for _ in range(n)]}
        else: custom[key] = {"nd": [rng.randint(0, 9) for _ in range(n + 2)]}
    a["custom"] = custom
    return a


def py_detections(a):
    xyxy = np.array(a["xyxy"], dtype=float).reshape(-1, 4)
    data = {k: py_value(v) for k, v in a["data"].items()}
    return Detections(xyxy=xyxy, class_id=None if a["class_id"] is None else np.array(a["class_id"], dtype=int),
                      confidence=None if a["confidence"] is None else np.array(a["confidence"], dtype=float),
                      tracker_id=None if a["tracker_id"] is None else np.array(a["tracker_id"], dtype=int),
                      data=data)


def sink_rows(rng):
    rows = []
    os.makedirs(".work/sink-oracle", exist_ok=True)
    for k in range(60):
        op = "sink_csv" if k % 2 == 0 else "sink_json"
        appends = [sink_append(rng, rng.choice([0, 1, 1, 2, 3, 4])) for _ in range(rng.randint(0, 3))]
        path = f".work/sink-oracle/{k}"
        sink = CSVSink(path) if op == "sink_csv" else JSONSink(path)
        sink.open()
        for a in appends:
            sink.append(py_detections(a), {key: py_value(v) for key, v in a["custom"].items()})
        sink.close() if op == "sink_csv" else sink.write_and_close()
        with open(path, newline="") as f:
            rows.append((op, {"appends": appends}, f.read()))
    return rows


def main():
    rng = random.Random(SEED)
    os.makedirs(OUT, exist_ok=True)
    write("tools_slicer", slicer_rows(rng))
    write("tools_line", line_rows(rng))
    rows = sink_rows(rng)
    write("tools_sinks", rows)


if __name__ == "__main__":
    main()
