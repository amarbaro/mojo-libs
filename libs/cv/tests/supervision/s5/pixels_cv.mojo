# Row driver for tests/cases/pixels_cv.txt (built to build/pixels_cv): one JSON line per row, {"out": path} for image rows.
# cv_put_text_aa and cv_text_size are descoped this wave (cv2 5.x text is an embedded TTF, see src/supervision/_cv/README.md):
# they print {"error": "descoped"} so the harness reports FAIL instead of a silent skip.
from json import parse, Json
from mojocv.imgproc import cvt_color
from supervision._cv.png import imread, imwrite
from supervision._cv.ops import add_weighted, convert_scale_abs, apply_color_map_jet
from supervision._cv import draw


def ints(j: Json) -> List[Int]:
    var out = List[Int]()
    for i in range(j.len()):
        out.append(j.at(i).int())
    return out^


def color_of(j: Json) -> List[Float64]:
    var out = List[Float64]()
    for i in range(j.len()):
        out.append(j.at(i).num())
    return out^


def run_row(line: String) raises -> String:
    var cols = line.split("\t")
    var op = String(cols[0])
    var args = parse(String(cols[1]))
    var p = args.get("params")
    var out_path = ".work/tests-out/px_" + op + ".png"
    if op == "cv_text_size" or op == "cv_put_text_aa":
        return '{"error": "descoped"}'
    var img = imread(String(args.text("input")))
    if op == "cv_circle_outline":
        var c = ints(p.get("center"))
        draw.circle(img, c[0], c[1], p.get("radius").int(), color_of(p.get("color")), p.get("thickness").int())
    elif op == "cv_ellipse_arc":
        var c = ints(p.get("center"))
        var a = ints(p.get("axes"))
        draw.ellipse(img, c[0], c[1], a[0], a[1], p.get("angle").int(), p.get("start").int(), p.get("end").int(), color_of(p.get("color")), p.get("thickness").int())
    elif op == "cv_polylines_open" or op == "cv_polylines_closed":
        var xs = List[Int]()
        var ys = List[Int]()
        var pts = p.get("pts")
        for i in range(pts.len()):
            xs.append(pts.at(i).at(0).int())
            ys.append(pts.at(i).at(1).int())
        draw.polylines(img, xs, ys, p.get("closed").truthy(), color_of(p.get("color")), p.get("thickness").int())
    elif op == "cv_fill_nonconvex":
        var xs = List[Int]()
        var ys = List[Int]()
        var pts = p.get("pts")
        for i in range(pts.len()):
            xs.append(pts.at(i).at(0).int())
            ys.append(pts.at(i).at(1).int())
        draw.fill_poly(img, [xs^], [ys^], color_of(p.get("color")))
    elif op == "cv_add_weighted":
        img = add_weighted(img, p.get("alpha").num(), imread(String(args.text("input2"))), p.get("beta").num(), p.get("gamma").num())
    elif op == "cv_convert_scale_abs":
        img = convert_scale_abs(img, p.get("alpha").num(), p.get("beta").num())
    elif op == "cv_apply_colormap":
        img = apply_color_map_jet(img)
    elif op == "cv_png_roundtrip":
        pass
    else:
        raise Error("unknown op " + op)
    imwrite(out_path, img, 9 if op == "cv_png_roundtrip" else 6)
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
