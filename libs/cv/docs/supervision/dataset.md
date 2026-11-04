# dataset (lane S3)

`src/supervision/dataset/`: port of `supervision/dataset/` for box annotations.

| File | Python source | Notes |
|---|---|---|
| `core.mojo` | `core.py` DetectionDataset | lazy (paths on disk), split, merge, `map_detections_class_id` |
| `coco.mojo` | `formats/coco.py` | JSON through mojo-json, `indent=3`; `date_captured` is a parameter (Python writes `now()`) |
| `yolo.mojo` | `formats/yolo.py` | box rows, trailing confidence, pose keypoints dropped, `%.5f` via snprintf |
| `voc.mojo`, `xml.mojo` | `formats/pascal_voc.py` | minidom `toprettyxml` layout; defusedxml-style DTD refusal |
| `utils.mojo`, `pyrandom.mojo` | `utils.py` | `random.Random(seed).shuffle` (MT19937) so a split picks the same images |
| `yaml.mojo`, `datayaml.mojo` | `utils/file.py`, yolo data.yaml readers | PyYAML scalar resolution, byte-exact `yaml.dump` of `nc`/`names` incl. width-80 wrapping |
| `fsutil.mojo`, `numfmt.mojo` | pathlib, PIL header, `format(x, ".5f")` | image size from PNG/JPEG/BMP/GIF headers |
| `rowio.mojo`, `rowds.mojo`, `dataset_*.mojo` | | row binaries for `tests/run.sh` |

## Not ported (each raises `... not ported yet`)

Segmentation: COCO polygons and RLE, YOLO polygon and OBB rows, VOC `<polygon>`, mask export.
They need `polygon_to_mask`, `mask_to_polygons`, `approximate_mask_with_polygons` (S1 converters, mojo-cv `fillPoly` and
`findContours`). LabelMe and CreateML formats, `ClassificationDataset`, in-memory image dicts.
EXIF orientation is not applied to image sizes. Non-ASCII file names in `find_duplicates` messages follow insertion order,
not Python's set order.

## Gate

`tests/run.sh` row files `dataset_{coco,yolo,voc}` (H4 fixtures, byte-equal bundles), `dataset_s3_*` (13x9 images, float
boxes, YOLO label quirks; `tools/gen_s3_dataset.py`), `dataset_split` (shuffle/split/class utils; `tools/gen_s3_split.py`),
`dataset_yaml` (`tools/gen_s3_yaml.py`). Build: `mojo build -I src -I <mojo-json>/src -o build/<stem> src/supervision/dataset/<stem>.mojo`.
