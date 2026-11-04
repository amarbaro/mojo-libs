#!/usr/bin/env python3
"""Oracle rows for the metrics port (lane H3).

Writes tests/cases/metrics_{map,pr,mar,cm}.txt in the boss row format:
    <op>\t<args JSON>\t<expected JSON>
Line 1 of each file: `# gen: tools/gen_metrics.py seed=<n>`.
Floats compare abs+rel 1e-6; NaN is written as "nan".

Ops (detections are per-image lists; boxes rounded to 3 dp, so the args are exact):
  map50      pred, target, metric_target -> float         MeanAveragePrecision.map50
  map50_95   pred, target, metric_target -> float         MeanAveragePrecision.map50_95
  precision  pred, target, averaging -> list[float]       precision_scores per IoU threshold
  recall     pred, target, averaging -> list[float]       recall_scores per IoU threshold
  f1         pred, target, averaging -> list[float]       f1_scores per IoU threshold
  mar        pred, target -> list[float]                  MeanAverageRecall.recall_scores
  confusion  pred, target, classes, conf, iou -> nested   ConfusionMatrix.matrix

Oracle: Python supervision at .work/supervision-develop/src. Run with:
  PYTHONPATH=.work/supervision-develop/src .work/oracle-venv/bin/python tools/gen_metrics.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import supervision as sv
from supervision.metrics import (
    AveragingMethod,
    F1Score,
    MeanAveragePrecision,
    MeanAverageRecall,
    MetricTarget,
    Precision,
    Recall,
)
from supervision.metrics.detection import ConfusionMatrix

SEED = 20261104
N_RANDOM_SCENES = 25
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests" / "cases"
AVERAGING = {"macro": AveragingMethod.MACRO, "weighted": AveragingMethod.WEIGHTED}
CLASSES = ["c0", "c1", "c2", "c3"]
FILES = {"map": "metrics_map.txt", "pr": "metrics_pr.txt",
         "mar": "metrics_mar.txt", "cm": "metrics_cm.txt"}


def fail(step: str, reason: str) -> None:
    print(f"FAIL {step}: {reason}", file=sys.stderr)
    sys.exit(1)


def r3(x) -> list:
    return np.round(np.asarray(x, dtype=float), 3).tolist()


def pred_obj(entry: dict) -> sv.Detections:
    return sv.Detections(
        xyxy=np.asarray(entry["xyxy"], dtype=np.float32).reshape(-1, 4),
        class_id=np.asarray(entry["class_id"], dtype=int),
        confidence=np.asarray(entry["confidence"], dtype=np.float32),
    )


def target_obj(entry: dict) -> sv.Detections:
    return sv.Detections(
        xyxy=np.asarray(entry["xyxy"], dtype=np.float32).reshape(-1, 4),
        class_id=np.asarray(entry["class_id"], dtype=int),
    )


def clean(x):
    if isinstance(x, float):
        return "nan" if math.isnan(x) else x
    if isinstance(x, list):
        return [clean(v) for v in x]
    return x


def row(op: str, args: dict, expected) -> str:
    a = json.dumps(args, sort_keys=True, separators=(",", ":"))
    e = json.dumps(clean(expected), separators=(",", ":"))
    return f"{op}\t{a}\t{e}"


def random_scene(rng: np.random.Generator) -> tuple[list[dict], list[dict]]:
    """Multi-image scene: jittered matches, wrong-class hits, false positives, misses."""
    preds, tgts = [], []
    for _ in range(int(rng.integers(1, 5))):
        gt_xyxy, gt_cls = [], []
        for _ in range(int(rng.integers(0, 7))):
            x1, y1 = rng.uniform(0, 200, 2)
            w, h = rng.uniform(5, 60, 2)
            gt_xyxy.append([x1, y1, x1 + w, y1 + h])
            gt_cls.append(int(rng.integers(0, 4)))
        p_xyxy, p_cls, p_conf = [], [], []
        for box, c in zip(gt_xyxy, gt_cls):
            if rng.random() < 0.7:
                p_xyxy.append((np.asarray(box) + rng.uniform(-4, 4, 4)).tolist())
                p_cls.append(c if rng.random() > 0.15 else int(rng.integers(0, 4)))
                p_conf.append(float(rng.uniform(0.2, 1.0)))
        for _ in range(int(rng.integers(0, 4))):
            x1, y1 = rng.uniform(0, 200, 2)
            w, h = rng.uniform(5, 60, 2)
            p_xyxy.append([x1, y1, x1 + w, y1 + h])
            p_cls.append(int(rng.integers(0, 4)))
            p_conf.append(float(rng.uniform(0.05, 1.0)))
        preds.append({"xyxy": r3(p_xyxy), "class_id": p_cls, "confidence": r3(p_conf)})
        tgts.append({"xyxy": r3(gt_xyxy), "class_id": gt_cls})
    return preds, tgts


def edge_scenes() -> list[tuple[str, list[dict], list[dict]]]:
    box = [[0.0, 0.0, 10.0, 10.0]]
    empty = {"xyxy": [], "class_id": [], "confidence": []}
    empty_t = {"xyxy": [], "class_id": []}
    one = {"xyxy": box, "class_id": [0], "confidence": [0.9]}
    one_t = {"xyxy": box, "class_id": [0]}
    return [
        ("edge_empty_both", [empty], [empty_t]),
        ("edge_empty_preds", [empty], [one_t]),
        ("edge_empty_targets", [one], [empty_t]),
        ("edge_perfect_match", [one], [one_t]),
        ("edge_duplicate_preds", [{"xyxy": box * 3, "class_id": [0, 0, 0],
                                   "confidence": [0.9, 0.8, 0.7]}], [one_t]),
        ("edge_wrong_class", [{"xyxy": box, "class_id": [1], "confidence": [0.9]}], [one_t]),
        ("edge_iou_below_half", [{"xyxy": [[0.0, 0.0, 4.0, 4.0]], "class_id": [0],
                                  "confidence": [0.9]}], [one_t]),
    ]


def build_rows() -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {k: [] for k in FILES}
    rng = np.random.default_rng(SEED)
    scenes = [(f"random_{i}", *random_scene(rng)) for i in range(N_RANDOM_SCENES)]
    scenes += edge_scenes()

    for name, pj, tj in scenes:
        pd = [pred_obj(p) for p in pj]
        td = [target_obj(t) for t in tj]
        common = {"pred": pj, "target": tj, "name": name}

        res = MeanAveragePrecision(metric_target=MetricTarget.BOXES).update(pd, td).compute()
        rows["map"].append(row("map50", {**common, "metric_target": "boxes"}, res.map50))
        rows["map"].append(row("map50_95", {**common, "metric_target": "boxes"}, res.map50_95))

        for op, cls, field in (("precision", Precision, "precision_scores"),
                               ("recall", Recall, "recall_scores"),
                               ("f1", F1Score, "f1_scores")):
            for avg in ("weighted", "macro"):
                r = cls(metric_target=MetricTarget.BOXES,
                        averaging_method=AVERAGING[avg]).update(pd, td).compute()
                rows["pr"].append(row(op, {**common, "averaging": avg},
                                      np.asarray(getattr(r, field)).tolist()))

        mar = MeanAverageRecall(metric_target=MetricTarget.BOXES).update(pd, td).compute()
        rows["mar"].append(row("mar", common, np.asarray(mar.recall_scores).tolist()))

        cm = ConfusionMatrix.from_detections(pd, td, classes=CLASSES,
                                             conf_threshold=0.3, iou_threshold=0.5)
        rows["cm"].append(row("confusion", {**common, "classes": CLASSES,
                                            "conf": 0.3, "iou": 0.5},
                              np.asarray(cm.matrix).tolist()))
    return rows


def main() -> None:
    rows = build_rows()
    OUT.mkdir(parents=True, exist_ok=True)
    total = 0
    for key, lines in rows.items():
        if not lines:
            fail(key, "no rows generated")
        head = f"# gen: tools/gen_metrics.py seed={SEED}\n"
        (OUT / FILES[key]).write_text(head + "\n".join(lines) + "\n")
        total += len(lines)
        print(f"{FILES[key]}: {len(lines)} rows")
    if total < 150:
        fail("count", f"{total} rows < floor 150")
    print(f"total: {total} rows")


if __name__ == "__main__":
    main()
