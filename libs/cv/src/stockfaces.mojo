# mcv-faces MODEL OUT LIST [gpu=16|32] [boxes=1]: SCRFD faces (mojo-faces, imported, not copied) in each image of LIST,
# upright as the file shows it. One JSON line per image for scripts/mcv-stockcheck: face count, the largest face's share of
# the picture, best score. boxes=1 writes mojo-faces' detect_list format instead, the input of its tools/cmp_faces.py.
# gpu=16|32 runs the GPU runner (start under `gpu-wait run --timeout S`); without it the CPU runner never opens the device.
from std.sys import argv
from faces.onnx import Model
from faces.image import load_rgb
from faces.detect import detect
from mojocv.mat import Mat, load
from mojocv.stockcheck import _load_ppm
from faces.gpu.net import GpuNet
from faces.gpu.detect import detect_gpu
from max.gpu.host import DeviceContext


def _esc(s: String) -> String:
    var o = String()
    for c in s.codepoints():
        if c == Codepoint.ord('"') or c == Codepoint.ord("\\"):
            o += "\\"
        o += String(c)
    return o^


def _rgb(path: String) raises -> Mat[DType.uint8]:
    """A picture as RGB: `.ppm` (P6) and `.mcv` (BGR) files come from scripts/decode-stock.sh, which reads the grey, palette,
    16-bit and interlaced PNGs that imkit's loader refuses; anything else goes through mojo-faces' load_rgb."""
    if not (path.endswith(".ppm") or path.endswith(".mcv")):
        return load_rgb(path)
    var m = _load_ppm(path) if path.endswith(".ppm") else load[DType.uint8](path)  # both give B, G, R
    if m.ch != 3:
        raise Error("mcv-faces: " + path + " has " + String(m.ch) + " channels, wanted 3")
    for i in range(m.rows * m.cols):
        var t = m.data[3 * i]
        m.data[3 * i] = m.data[3 * i + 2]
        m.data[3 * i + 2] = t
    return m^


def main() raises:
    var a = argv()
    if len(a) < 4:
        raise Error("usage: mcv-faces MODEL OUT LIST [gpu=16|32] [boxes=1]")
    var arm = 0
    var boxes = False
    for i in range(4, len(a)):
        var s = String(a[i])
        if s == "gpu=16":
            arm = 16
        elif s == "gpu=32":
            arm = 32
        elif s == "boxes=1":
            boxes = True
        else:
            raise Error("mcv-faces: unknown option " + s)
    var m = Model(String(a[1]))
    var net = Optional[GpuNet](None)
    if arm > 0:
        net = GpuNet(DeviceContext(), m, arm == 16)
    var out = open(String(a[2]), "w")
    for line in open(String(a[3]), "r").read().split("\n"):
        var p = String(line)
        if p == "":
            continue
        var l = String()
        try:
            var img = _rgb(p)
            var faces = detect_gpu(net.value(), img) if arm > 0 else detect(m, img)
            if boxes:
                for f in faces:
                    l += p + " " + String(f.score)
                    for k in range(4):
                        l += " " + String(f.box[k])
                    for k in range(10):
                        l += " " + String(f.kps[k])
                    l += "\n"
                var ck = UInt64(0)
                for i in range(len(img.data)):
                    ck += UInt64(img.data[i]) * UInt64(i % 65521 + 1)
                l += String("n ", p, " ", len(faces), " ", img.cols, " ", img.rows, " ", ck, "\n")
            else:
                var best = Float32(0)
                var area = Float64(0)
                for f in faces:
                    var w = max(Float32(0), min(f.box[2], Float32(img.cols)) - max(f.box[0], Float32(0)))
                    var h = max(Float32(0), min(f.box[3], Float32(img.rows)) - max(f.box[1], Float32(0)))
                    area = max(area, Float64(w) * Float64(h))
                    best = max(best, f.score)
                l = String('{"file":"', _esc(p), '","w":', img.cols, ',"h":', img.rows, ',"faces":', len(faces), ',"largest":', area / Float64(img.cols * img.rows), ',"score":', best, "}\n")
        except e:
            l = String('{"file":"', _esc(p), '","error":"', _esc(String(e)), '"}\n') if not boxes else String("err ", p, " ", String(e), "\n")
        out.write(l)
