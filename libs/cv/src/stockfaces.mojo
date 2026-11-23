# mcv-faces MODEL OUT LIST [gpu=16|32] [boxes=1]: SCRFD faces (mojo-faces, imported, not copied) in each image of LIST,
# upright as the file shows it. One JSON line per image for scripts/mcv-stockcheck: face count, the largest face's share of
# the picture, best score. boxes=1 writes mojo-faces' detect_list format instead, the input of its tools/cmp_faces.py.
# gpu=16|32 runs the GPU runner (start under `gpu-wait run --timeout S`); without it the CPU runner never opens the device.
# Two stages, so the GPU slot is held for detection only: `mcv-faces - OUT LIST prep=1 cache=DIR` decodes and letterboxes on
# the CPU (no device; run shards in parallel; resumable, a valid cache file is kept), then `mcv-faces MODEL OUT LIST gpu=16
# cache=DIR` reads the cache and runs detection. The cache key is path, size and mtime, so a changed file is not served stale.
from std.sys import argv
from std.os import stat
from std.os.path import exists
from std.time import perf_counter_ns
from std.memory import bitcast
from gpunet.onnx import Model
from faces.image import load_rgb
from faces.detect import detect, decode, Face
from gpunet.nn import Arr
from mojocv.imgproc import resize
from mojocv.mat import Mat, load
from mojocv.stockcheck import _load_ppm
from gpunet.gpu.net import GpuNet
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


def _key(p: String) raises -> String:
    """FNV-1a 64 of path, size and mtime: the cache file name stem."""
    var st = stat(p)
    var k = String(p, "|", Int(st.st_size), "|", Int(st.st_mtimespec.as_nanoseconds()))
    var h = UInt64(14695981039346656037)
    for b in k.as_bytes():
        h = (h ^ UInt64(b)) * UInt64(1099511628211)
    var hx = String()
    for i in range(16):
        hx += String("0123456789abcdef"[byte=Int((h >> UInt64(60 - 4 * i)) & 15)])
    return hx^


def _u32le(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) | (Int(b[at + 1]) << 8) | (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)


def _prep(img: Mat[DType.uint8], file: String, size: Int = 640) raises:
    """Writes detect.letterbox's resize (nw x nh RGB) with the source size and scale: a 20-byte header (w, h, nw, nh, scale
    bits, little-endian u32) then the pixels."""
    var ratio = Float64(img.rows) / Float64(img.cols)
    var nh: Int
    var nw: Int
    if ratio > 1.0:
        nh = size
        nw = Int(Float64(nh) / ratio)
    else:
        nw = size
        nh = Int(Float64(nw) * ratio)
    var scale = Float32(Float64(nh) / Float64(img.rows))
    var r = resize(img, nw, nh, 1)
    var hd = List[UInt8]()
    var v = List[UInt32]()
    v.append(UInt32(img.cols))
    v.append(UInt32(img.rows))
    v.append(UInt32(nw))
    v.append(UInt32(nh))
    v.append(bitcast[DType.uint32](scale))
    for x in v:
        for j in range(4):
            hd.append(UInt8((x >> UInt32(8 * j)) & 255))
    var f = open(file, "w")
    f.write_bytes(Span(hd))
    f.write_bytes(Span(unsafe_ptr=r.ptr(), length=nw * nh * 3))


def _valid(file: String) raises -> Bool:
    """A cache file is whole when its size is the header's 20 bytes plus nw * nh * 3."""
    if not exists(file):
        return False
    var n = Int(stat(file).st_size)
    if n < 20:
        return False
    var b = open(file, "r").read_bytes()
    return n == 20 + _u32le(b, 8) * _u32le(b, 12) * 3


def _cached(mut net: GpuNet, file: String, size: Int = 640) raises -> Tuple[Int, Int, List[Face]]:
    """Detection from a cache file: detect.letterbox's blob fill, then the GPU runner and detect.decode."""
    var b = open(file, "r").read_bytes()
    var nw = _u32le(b, 8)
    var nh = _u32le(b, 12)
    var scale = bitcast[DType.float32](UInt32(_u32le(b, 16)))
    var blob = Arr([1, 3, size, size])
    var plane = size * size
    for c in range(3):
        for p in range(plane):
            blob.d[c * plane + p] = (0.0 - 127.5) / 128.0
    for y in range(nh):
        for x in range(nw):
            for c in range(3):
                blob.d[c * plane + y * size + x] = (Float32(b[20 + (y * nw + x) * 3 + c]) - 127.5) / 128.0
    var feeds = Dict[String, Arr]()
    feeds[net.inputs[0]] = blob^
    return (_u32le(b, 0), _u32le(b, 4), decode(net.run(feeds^), net.outputs, scale))


def main() raises:
    var a = argv()
    if len(a) < 4:
        raise Error("usage: mcv-faces MODEL OUT LIST [gpu=16|32] [boxes=1]")
    var arm = 0
    var boxes = False
    var prep = False
    var cache = String()
    for i in range(4, len(a)):
        var s = String(a[i])
        if s == "prep=1":
            prep = True
        elif s.startswith("cache="):
            cache = String(s[byte=6:])
        elif s == "gpu=16":
            arm = 16
        elif s == "gpu=32":
            arm = 32
        elif s == "boxes=1":
            boxes = True
        else:
            raise Error("mcv-faces: unknown option " + s)
    if prep:  # CPU stage: one line per picture, state hit | made | error, ms spent on it
        if cache == "":
            raise Error("mcv-faces: prep=1 needs cache=DIR")
        var po = open(String(a[2]), "w")
        for line in open(String(a[3]), "r").read().split("\n"):
            var p = String(line)
            if p == "":
                continue
            var t0 = perf_counter_ns()
            var state = String("hit")
            var msg = String()
            try:
                var base = cache + "/" + _key(p)
                if not _valid(base + ".lb"):
                    _prep(_rgb(p), base + ".lb")
                    state = "made"
            except e:
                state = "error"
                msg = String(',"error":"', _esc(String(e)), '"')
            po.write(String('{"file":"', _esc(p), '","state":"', state, '","ms":', Float64(perf_counter_ns() - t0) / 1e6, msg, "}\n"))
        return
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
        if cache != "":  # GPU stage from the cache: detection only, no decode
            if arm == 0 or boxes:
                raise Error("mcv-faces: cache=DIR needs gpu=16|32 and no boxes=1")
            try:
                var r = _cached(net.value(), cache + "/" + _key(p) + ".lb")
                var iw = r[0]
                var ih = r[1]
                var faces = r[2].copy()
                var best = Float32(0)
                var area = Float64(0)
                for f in faces:
                    var w = max(Float32(0), min(f.box[2], Float32(iw)) - max(f.box[0], Float32(0)))
                    var h = max(Float32(0), min(f.box[3], Float32(ih)) - max(f.box[1], Float32(0)))
                    area = max(area, Float64(w) * Float64(h))
                    best = max(best, f.score)
                out.write(String('{"file":"', _esc(p), '","w":', iw, ',"h":', ih, ',"faces":', len(faces), ',"largest":', area / Float64(iw * ih), ',"score":', best, "}\n"))
            except e:
                out.write(String('{"file":"', _esc(p), '","error":"', _esc(String(e)), '"}\n'))
            continue
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
