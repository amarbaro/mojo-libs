# metrics (lane S2)

Port of supervision `metrics/` for box targets, on plain arrays (`Dets`), with `adapt.to_dets` from S0 `Detections`.

| file | Python source | entry |
|---|---|---|
| `coco.mojo` | `COCOEvaluator`, `MeanAveragePrecision` | `mean_average_precision(preds, targets, image_ids, max_dets)` -> `MapResult` |
| `prf.mojo` | `_ConfusionMatrixMetric`, `Precision`, `Recall`, `F1Score` | `prf(preds, targets, kind, averaging)` |
| `mar.mojo` | `MeanAverageRecall` | `mean_average_recall(preds, targets)` |
| `confmat.mojo` | `ConfusionMatrix.from_detections` | `confusion_matrix(preds, targets, n_classes, conf, iou)` |
| `iou.mojo`, `sortutil.mojo` | `box_iou_batch`, greedy matcher, numpy stable argsort | helpers |

Float rules that matter: boxes and confidences are float32 (round on load); `box_iou_batch` computes in float64 and returns float32; the P/R/F1 and mAR IoU thresholds are float32; COCO mAP thresholds are float64 `linspace` values reproduced bit for bit.

Not ported: mask and oriented-box targets, small/medium/large buckets of P/R/F1/mAR, keypoint mAP (deferred by the boss), plots, pandas, `class_mapping`. Paths without oracle rows (UNVERIFIED): `micro` averaging, `class_agnostic`, `iscrowd`/`ignore` fields, `image_indices`, custom max-det limits, mAP per-class and per-size values.

Gate: `tests/build_metrics.sh && tests/run.sh tests/cases/metrics_*.txt` (320 rows).
Trap: `input()` cuts lines near 1 KB in Mojo 1.2; read `/dev/stdin` whole.
