# Row driver for tests/cases/pixels_annotators.txt (built to build/pixels_annotators). pixel_label is descoped (text).
from json import parse, Json
from mojocv.mat import Mat
from supervision.detection.core import Detections
from supervision.draw.color import Color, ColorPalette
from supervision.key_points.core import KeyPoints
from supervision.key_points.annotators import vertex_annotate
from supervision.annotators.core import box_annotate, circle_annotate, dot_annotate, mask_annotate, polygon_annotate, blur_annotate, pixelate_annotate, halo_annotate, trace_annotate
from supervision.annotators.utils import Trace
from supervision._cv.png import imread, imwrite
from supervision._cv import draw


def ints(j: Json) -> List[Int]:
    var out = List[Int]()
    for i in range(j.len()):
        out.append(j.at(i).int())
    return out^


def build(p: Json, h: Int, w: Int, with_mask: Bool) raises -> Detections:
    var xyxy = List[Float64]()
    var bx = p.get("xyxy")
    for i in range(bx.len()):
        for k in range(4):
            xyxy.append(bx.at(i).at(k).num())
    var d = Detections(xyxy^)
    d.set_class_id(ints(p.get("class_id")))
    var conf = List[Float64]()
    for i in range(p.get("confidence").len()):
        conf.append(p.get("confidence").at(i).num())
    d.set_confidence(conf^)
    if with_mask and p.has("polygons"):
        var polys = p.get("polygons")
        var mask = List[UInt8]()
        for i in range(polys.len()):
            var m = Mat[DType.uint8](h, w, 1)
            var xs = List[Int]()
            var ys = List[Int]()
            for k in range(polys.at(i).len()):
                xs.append(polys.at(i).at(k).at(0).int())
                ys.append(polys.at(i).at(k).at(1).int())
            draw.fill_poly(m, [xs^], [ys^], [1.0])
            for q in range(h * w):
                mask.append(m.data[q])
        d.set_mask(mask^, h, w)
    return d^


def run_row(line: String) raises -> String:
    var cols = line.split("\t")
    var op = String(cols[0])
    var args = parse(String(cols[1]))
    if op == "pixel_label":
        return '{"error": "descoped"}'
    var p = args.get("params")
    var kw = p.get("kwargs")
    var scene = imread(String(args.text("input")))
    var pal = ColorPalette.DEFAULT()
    var det = build(p, scene.rows, scene.cols, True)
    if op == "pixel_box":
        box_annotate(scene, det, pal, kw.get("thickness").int())
    elif op == "pixel_mask":
        mask_annotate(scene, det, pal, kw.get("opacity").num())
    elif op == "pixel_polygon":
        polygon_annotate(scene, det, pal, kw.get("thickness").int())
    elif op == "pixel_circle":
        circle_annotate(scene, det, pal, kw.get("thickness").int())
    elif op == "pixel_dot":
        dot_annotate(scene, det, pal, kw.get("radius").int())
    elif op == "pixel_halo":
        halo_annotate(scene, det, pal, kw.get("opacity").num(), kw.get("kernel_size").int())
    elif op == "pixel_blur":
        blur_annotate(scene, det, kw.get("kernel_size").int())
    elif op == "pixel_pixelate":
        pixelate_annotate(scene, det, kw.get("pixel_size").int())
    elif op == "pixel_trace":
        var tr = Trace(kw.get("trace_length").int(), 0)
        var frames = p.get("frames")
        for f in range(frames.len()):
            var xyxy = List[Float64]()
            for i in range(frames.at(f).len()):
                for k in range(4):
                    xyxy.append(frames.at(f).at(i).at(k).num())
            var fd = Detections(xyxy^)
            fd.set_class_id(ints(p.get("class_id")))
            fd.set_tracker_id(ints(p.get("tracker_id")))
            trace_annotate(scene, fd, tr, pal, kw.get("thickness").int())
    elif op == "pixel_keypoints":
        var xy = List[Float64]()
        var j = p.get("xy")
        for d in range(j.len()):
            for q in range(j.at(d).len()):
                xy.append(j.at(d).at(q).at(0).num())
                xy.append(j.at(d).at(q).at(1).num())
        vertex_annotate(scene, KeyPoints(xy^, j.len(), j.at(0).len()), Color.ROBOFLOW(), kw.get("radius").int())
    else:
        raise Error("unknown op " + op)
    var out_path = ".work/tests-out/px_" + op + ".png"
    imwrite(out_path, scene)
    return '{"out": "' + out_path + '"}'


def main() raises:
    var text = open("/dev/stdin", "r").read()
    for ln in text.split("\n"):
        var line = String(ln)
        if line.byte_length() == 0:
            continue
        try:
            print(run_row(line))
        except e:
            print('{"error": "' + String(e).replace('"', "'") + '"}')
