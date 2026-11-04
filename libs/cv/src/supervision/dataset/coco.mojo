"""COCO dataset format (dataset/formats/coco.py): boxes only; segmentation raises."""
from std.collections import Dict
from std.math import isfinite
from std.os.path import isdir, realpath
from json import Json, parse
from supervision.config import AREA_DATA_FIELD, ISCROWD_DATA_FIELD
from supervision.dataset.core import DetectionDataset, map_detections_class_id, save_dataset_images
from supervision.dataset.fsutil import image_size_wh, join, mkdirs, name_of, parent_of, read_text, write_text
from supervision.dataset.utils import check_no_basename_collisions, py_repr
from supervision.detection.core import DataCol, Detections


def _sorted_category_order(cats: Json) -> List[Int]:
    """Indices of `cats` ordered by category id (stable, as Python's sorted)."""
    var order = List[Int]()
    var ids = List[Float64]()
    for i in range(cats.len()):
        order.append(i)
        ids.append(cats.at(i).get("id").num())
    for i in range(1, len(order)):
        var j = i
        while j > 0 and ids[order[j]] < ids[order[j - 1]]:
            var t = order[j]
            order[j] = order[j - 1]
            order[j - 1] = t
            j -= 1
    return order^


def _detections(anns: List[Json]) raises -> Detections:
    """coco_annotations_to_detections for box-only annotations (use_iscrowd=True)."""
    if len(anns) == 0:
        return Detections.empty()
    var xyxy = List[Float64]()
    var ids = List[Int]()
    var iscrowd = List[Float64]()
    var area = List[Float64]()
    for a in anns:
        if a.get("segmentation").len() > 0:
            raise Error("COCO segmentation (masks) is not ported yet")
        ids.append(a.get("category_id").int())
        var bb = a.get("bbox")
        var bw = bb.at(2).num()
        var bh = bb.at(3).num()
        if bw < 0 or bh < 0:
            raise Error(
                "Invalid box extent (" + bb.at(2).dumps() + ", " + bb.at(3).dumps() + ") in COCO annotation "
                + (a.get("id").dumps() if a.has("id") else String("<no id>"))
                + "; expected a non-negative width and height."
            )
        var x = Float32(bb.at(0).num())
        var y = Float32(bb.at(1).num())
        xyxy.append(Float64(x))
        xyxy.append(Float64(y))
        xyxy.append(Float64(Float32(bw) + x))
        xyxy.append(Float64(Float32(bh) + y))
        iscrowd.append(a.get("iscrowd").num() if a.has("iscrowd") else 0.0)
        area.append(a.get("area").num() if a.has("area") else bw * bh)
    var d = Detections(xyxy^)
    d.set_class_id(ids^)
    d.set_data(DataCol(ISCROWD_DATA_FIELD, iscrowd))
    d.set_data(DataCol(AREA_DATA_FIELD, area))
    d.validate()
    return d^


def from_coco(images_dir: String, annotations_path: String) raises -> DetectionDataset:
    var data = parse(read_text(annotations_path))
    var cats = data.get("categories")
    var classes = List[String]()
    for i in _sorted_category_order(cats):
        classes.append(cats.at(i).get("name").str())
    # category id -> class index (the last category of a repeated name wins, as the Python dict does)
    var name_to_id = Dict[String, Int]()
    for i in range(cats.len()):
        name_to_id[cats.at(i).get("name").str()] = cats.at(i).get("id").int()
    var mapping = Dict[Int, Int]()
    for ci in range(len(classes)):
        mapping[name_to_id[classes[ci]]] = ci
    var groups = Dict[Int, List[Json]]()
    var anns = data.get("annotations")
    for i in range(anns.len()):
        var a = anns.at(i)
        var iid = a.get("image_id").int()
        if iid not in groups:
            groups[iid] = List[Json]()
        groups[iid].append(a^)
    var images = data.get("images")
    var root = realpath(images_dir)
    var paths = List[String]()
    var dets = List[Detections]()
    var seen = Dict[String, Bool]()
    for i in range(images.len()):
        var im = images.at(i)
        var fname = im.get("file_name").str()
        var p = realpath(join(images_dir, fname))
        if p == root:
            raise Error(
                "COCO annotation refers to image " + py_repr(fname) + ", which resolves to the images directory "
                "itself (" + root + "). Expected a path to an image file."
            )
        if not p.startswith(root + "/"):
            raise Error(
                "COCO annotation refers to image " + py_repr(fname) + ", which resolves to " + p
                + " " + chr(0x2014) + " outside the images directory " + root + "."
            )
        if isdir(p):
            raise Error(
                "COCO annotation refers to image " + py_repr(fname) + ", which resolves to directory " + p
                + ". Expected a path to an image file."
            )
        if p in seen:
            raise Error(
                "COCO annotation file contains duplicate entries for image " + py_repr(fname)
                + ". Each image must appear at most once."
            )
        seen[p] = True
        var mine = List[Json]()
        var iid = im.get("id").int()
        if iid in groups:
            mine = groups[iid].copy()
        paths.append(p)
        dets.append(map_detections_class_id(mapping, _detections(mine)))
    return DetectionDataset(classes, paths, dets)


def save_coco_annotations(ds: DetectionDataset, path: String, date_captured: String) raises:
    """save_coco_annotations. `date_captured` is the stamp written for every image
    (Python writes datetime.now(); a caller that needs byte-stable output passes a fixed one)."""
    var names = List[String]()
    for p in ds.image_paths:
        names.append(name_of(p))
    check_no_basename_collisions(ds.image_paths, names, "COCO image")
    mkdirs(parent_of(path))
    var licenses = Json.array()
    var lic = Json.object()
    lic.set("id", Json.of(1))
    lic.set("url", Json.of("https://creativecommons.org/licenses/by/4.0/"))
    lic.set("name", Json.of("CC BY 4.0"))
    licenses.push(lic^)
    var categories = Json.array()
    for ci in range(len(ds.classes)):
        var c = Json.object()
        c.set("id", Json.of(ci + 1))
        c.set("name", Json.of(ds.classes[ci]))
        c.set("supercategory", Json.of("common-objects"))
        categories.push(c^)
    var images = Json.array()
    var annotations = Json.array()
    var image_id = 1
    var ann_id = 1
    for k in range(len(ds.image_paths)):
        var wh = image_size_wh(ds.image_paths[k])
        var im = Json.object()
        im.set("id", Json.of(image_id))
        im.set("license", Json.of(1))
        im.set("file_name", Json.of(names[k]))
        im.set("height", Json.of(wh[1]))
        im.set("width", Json.of(wh[0]))
        im.set("date_captured", Json.of(date_captured))
        images.push(im^)
        ref d = ds.annotations[k]
        if d.has_mask:
            raise Error("COCO export of masks is not ported yet")
        for i in range(len(d)):
            if not d.has_class_id:
                raise Error("Detections must include class_id for COCO export.")
            var x1 = Float32(d.xyxy[4 * i])
            var y1 = Float32(d.xyxy[4 * i + 1])
            var x2 = Float32(d.xyxy[4 * i + 2])
            var y2 = Float32(d.xyxy[4 * i + 3])
            var x_min = min(x1, x2)
            var x_max = max(x1, x2)
            var y_min = min(y1, y2)
            var y_max = max(y1, y2)
            var bw = x_max - x_min
            var bh = y_max - y_min
            var iscrowd = 0
            if d.has_data(ISCROWD_DATA_FIELD):
                iscrowd = Int(d.get_data(ISCROWD_DATA_FIELD).f[i])
            var area = Float64(bw * bh)
            if d.has_data(AREA_DATA_FIELD):
                var a = d.get_data(AREA_DATA_FIELD).f[i]
                if isfinite(a):
                    area = a
            var bbox = Json.array()
            bbox.push(Json.of(Float64(x_min)))
            bbox.push(Json.of(Float64(y_min)))
            bbox.push(Json.of(Float64(bw)))
            bbox.push(Json.of(Float64(bh)))
            var an = Json.object()
            an.set("id", Json.of(ann_id))
            an.set("image_id", Json.of(image_id))
            an.set("category_id", Json.of(d.class_id[i] + 1))
            an.set("bbox", bbox^)
            an.set("area", Json.of(area))
            an.set("segmentation", Json.array())
            an.set("iscrowd", Json.of(iscrowd))
            annotations.push(an^)
            ann_id += 1
        image_id += 1
    var root = Json.object()
    root.set("info", Json.object())
    root.set("licenses", licenses^)
    root.set("categories", categories^)
    root.set("images", images^)
    root.set("annotations", annotations^)
    write_text(path, root.dumps(False, 3))


def as_coco(ds: DetectionDataset, images_dir: String, annotations_path: String, date_captured: String) raises:
    save_dataset_images(ds, images_dir)
    save_coco_annotations(ds, annotations_path, date_captured)
