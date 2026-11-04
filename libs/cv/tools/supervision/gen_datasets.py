#!/usr/bin/env python3
"""Generate tests/fixtures/datasets/: tiny COCO, YOLO and VOC sets plus Python
supervision outputs (load -> save, split, merge) that the Mojo port must match byte-for-byte.

Step 1 (stdlib only): writes inputs with seed SEED: 4 PNG images per format, 8x8 px each,
    and annotations in that format's layout.
Step 2 (oracle, .work/oracle-venv): loads each input with Python supervision, saves it back,
    splits it, merges the halves, and writes every result under <fmt>/ref/.

Run: .work/oracle-venv/bin/python tools/gen_datasets.py
Exit non-zero on any failure: `FAIL <step>: <reason>`.
"""

from __future__ import annotations

import json
import random
import shutil
import struct
import sys
import zlib
from datetime import datetime
from pathlib import Path

SEED = 42
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "fixtures" / "datasets"
W = H = 8
N_IMAGES = 4
CLASSES = ["cat", "dog"]


def fail(step: str, reason: str) -> None:
    print(f"FAIL {step}: {reason}")
    sys.exit(1)


def png_bytes(rgb: list[tuple[int, int, int]]) -> bytes:
    """Minimal RGB PNG writer (no PIL): filter byte 0 per row, zlib, CRCs."""
    raw = b"".join(b"\x00" + bytes(c for px in rgb[y * W:(y + 1) * W] for c in px) for y in range(H))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def make_image(rng: random.Random) -> bytes:
    return png_bytes([(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(W * H)])


def make_boxes(rng: random.Random) -> list[tuple[int, float, float, float, float]]:
    """(class_id, x1, y1, x2, y2) in pixels, 1..2 boxes per image, inside the image."""
    boxes = []
    for _ in range(rng.randrange(1, 3)):
        x1 = rng.randrange(0, W - 2)
        y1 = rng.randrange(0, H - 2)
        x2 = rng.randrange(x1 + 1, W)
        y2 = rng.randrange(y1 + 1, H)
        boxes.append((rng.randrange(len(CLASSES)), float(x1), float(y1), float(x2), float(y2)))
    return boxes


def write_inputs() -> None:
    rng = random.Random(SEED)
    images = [(f"img_{i:03d}.png", make_image(rng), make_boxes(rng)) for i in range(N_IMAGES)]

    # COCO: one annotations.json, images/ directory
    coco_dir = OUT / "coco" / "in"
    (coco_dir / "images").mkdir(parents=True, exist_ok=True)
    coco = {"images": [], "annotations": [], "categories": []}
    for i, c in enumerate(CLASSES):
        coco["categories"].append({"id": i + 1, "name": c, "supercategory": "none"})
    ann_id = 1
    for img_id, (name, data, boxes) in enumerate(images, start=1):
        (coco_dir / "images" / name).write_bytes(data)
        coco["images"].append({"id": img_id, "file_name": name, "width": W, "height": H})
        for cls, x1, y1, x2, y2 in boxes:
            w, h = x2 - x1, y2 - y1
            coco["annotations"].append({
                "id": ann_id, "image_id": img_id, "category_id": cls + 1,
                "bbox": [x1, y1, w, h], "area": w * h, "iscrowd": 0, "segmentation": [],
            })
            ann_id += 1
    (coco_dir / "annotations.json").write_text(json.dumps(coco, indent=2) + "\n")

    # YOLO: images/, labels/, data.yaml
    yolo_dir = OUT / "yolo" / "in"
    (yolo_dir / "images").mkdir(parents=True, exist_ok=True)
    (yolo_dir / "labels").mkdir(parents=True, exist_ok=True)
    names = "\n".join(f"  {i}: {c}" for i, c in enumerate(CLASSES))
    (yolo_dir / "data.yaml").write_text(f"names:\n{names}\n")
    for name, data, boxes in images:
        (yolo_dir / "images" / name).write_bytes(data)
        lines = []
        for cls, x1, y1, x2, y2 in boxes:
            cx, cy = (x1 + x2) / 2 / W, (y1 + y2) / 2 / H
            lines.append(f"{cls} {cx:.6f} {cy:.6f} {(x2 - x1) / W:.6f} {(y2 - y1) / H:.6f}")
        (yolo_dir / "labels" / (Path(name).stem + ".txt")).write_text("\n".join(lines) + "\n")

    # Pascal VOC: images/ (PNG bytes), annotations/*.xml
    voc_dir = OUT / "voc" / "in"
    (voc_dir / "images").mkdir(parents=True, exist_ok=True)
    (voc_dir / "annotations").mkdir(parents=True, exist_ok=True)
    for name, data, boxes in images:
        (voc_dir / "images" / name).write_bytes(data)
        objs = "".join(
            f"<object><name>{CLASSES[cls]}</name><pose>Unspecified</pose><truncated>0</truncated>"
            f"<difficult>0</difficult><bndbox><xmin>{int(x1)}</xmin><ymin>{int(y1)}</ymin>"
            f"<xmax>{int(x2)}</xmax><ymax>{int(y2)}</ymax></bndbox></object>"
            for cls, x1, y1, x2, y2 in boxes
        )
        xml = (f"<annotation><folder>images</folder><filename>{name}</filename>"
               f"<size><width>{W}</width><height>{H}</height><depth>3</depth></size>"
               f"<segmented>0</segmented>{objs}</annotation>\n")
        (voc_dir / "annotations" / (Path(name).stem + ".xml")).write_text(xml)


def run_oracle() -> None:
    try:
        import supervision as sv
        from supervision.dataset.formats import coco as coco_fmt
    except ImportError as e:
        fail("oracle-import", f"{e}; .work/oracle-venv needs supervision (H1 owns it)")

    # supervision stamps COCO "date_captured" with datetime.now(): pin it so regeneration is byte-stable.
    class _PinnedDatetime(datetime):
        @classmethod
        def now(cls, tz=None):  # type: ignore[override]
            return datetime(2020, 1, 1, 0, 0, 0)

    coco_fmt.datetime = _PinnedDatetime

    def save_all(ds, fmt: str, tag: str) -> None:
        d = OUT / fmt / "ref" / tag
        shutil.rmtree(d, ignore_errors=True)
        imgs, anns = d / "images", d / "annotations"
        try:
            if fmt == "coco":
                ds.as_coco(images_directory_path=str(imgs), annotations_path=str(d / "annotations.json"))
            elif fmt == "yolo":
                ds.as_yolo(images_directory_path=str(imgs), annotations_directory_path=str(d / "labels"),
                           data_yaml_path=str(d / "data.yaml"))
            else:
                ds.as_pascal_voc(images_directory_path=str(imgs), annotations_directory_path=str(anns))
        except Exception as e:  # noqa: BLE001 - reported with the step name
            fail(f"save-{fmt}-{tag}", repr(e))

    for fmt in ("coco", "yolo", "voc"):
        src = OUT / fmt / "in"
        try:
            if fmt == "coco":
                ds = sv.DetectionDataset.from_coco(str(src / "images"), str(src / "annotations.json"))
            elif fmt == "yolo":
                ds = sv.DetectionDataset.from_yolo(str(src / "images"), str(src / "labels"), str(src / "data.yaml"))
            else:
                ds = sv.DetectionDataset.from_pascal_voc(str(src / "images"), str(src / "annotations"))
        except Exception as e:  # noqa: BLE001
            fail(f"load-{fmt}", repr(e))
        save_all(ds, fmt, "roundtrip")
        train, valid = ds.split(split_ratio=0.5, random_state=SEED, shuffle=True)
        save_all(train, fmt, "split_train")
        save_all(valid, fmt, "split_valid")
        merged = sv.DetectionDataset.merge([train, valid])
        save_all(merged, fmt, "merge")
        print(f"ok {fmt}: {len(ds)} images, split {len(train)}+{len(valid)}, merged {len(merged)}")


def verify_resave() -> None:
    """Load each ref/roundtrip, save it again, and require byte equality with the reference."""
    import supervision as sv

    scratch = ROOT / ".work" / "H4-resave"
    shutil.rmtree(scratch, ignore_errors=True)
    for fmt in ("coco", "yolo", "voc"):
        src = OUT / fmt / "ref" / "roundtrip"
        out = scratch / fmt
        try:
            if fmt == "coco":
                ds = sv.DetectionDataset.from_coco(str(src / "images"), str(src / "annotations.json"))
                ds.as_coco(images_directory_path=str(out / "images"), annotations_path=str(out / "annotations.json"))
            elif fmt == "yolo":
                ds = sv.DetectionDataset.from_yolo(str(src / "images"), str(src / "labels"), str(src / "data.yaml"))
                ds.as_yolo(images_directory_path=str(out / "images"), annotations_directory_path=str(out / "labels"),
                           data_yaml_path=str(out / "data.yaml"))
            else:
                ds = sv.DetectionDataset.from_pascal_voc(str(src / "images"), str(src / "annotations"))
                ds.as_pascal_voc(images_directory_path=str(out / "images"), annotations_directory_path=str(out / "annotations"))
        except Exception as e:  # noqa: BLE001
            fail(f"resave-{fmt}", repr(e))
        for ref_file in sorted(p for p in src.rglob("*") if p.is_file()):
            got = out / ref_file.relative_to(src)
            if not got.is_file() or got.read_bytes() != ref_file.read_bytes():
                fail(f"resave-{fmt}", f"{ref_file.relative_to(src)} differs after load->save")
    shutil.rmtree(scratch, ignore_errors=True)
    print("ok resave: load->save of every roundtrip reference is byte-equal")


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    write_inputs()
    run_oracle()
    verify_resave()


if __name__ == "__main__":
    main()
