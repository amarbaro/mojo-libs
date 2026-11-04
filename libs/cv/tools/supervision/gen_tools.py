#!/usr/bin/env python3
"""Oracle rows for the detection tools (S4). Run: .work/oracle-venv/bin/python -I tools/gen_tools.py
Row: <op>\t<args JSON>\t<expected JSON>; line 1 = '# gen: tools/gen_tools.py seed=<n>'.
Errors: expected {"error": "<PythonExceptionName>"}."""
import json, os, random, sys

import numpy as np

from supervision.detection.tools.inference_slicer import InferenceSlicer

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


def main():
    rng = random.Random(SEED)
    os.makedirs(OUT, exist_ok=True)
    write("tools_slicer", slicer_rows(rng))


if __name__ == "__main__":
    main()
