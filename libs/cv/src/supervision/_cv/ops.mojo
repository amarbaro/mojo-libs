# Pixel ops of cv2's core/imgproc that supervision calls and mojo-cv lacks: addWeighted, convertScaleAbs, applyColorMap(JET).
from mojocv.mat import Mat
from mojocv.imgproc import rint
from supervision._cv.jet import JET_TEXT

comptime Img = Mat[DType.uint8]


def _sat(v: Float32) -> UInt8:
    var r = rint(Float64(v))
    return UInt8(0 if r < 0 else (255 if r > 255 else r))


def add_weighted(a: Img, alpha: Float64, b: Img, beta: Float64, gamma: Float64) raises -> Img:
    """cv2.addWeighted on uint8: saturate(round(a*alpha + b*beta + gamma)) in float32."""
    if not a.same_shape(b):
        raise Error("add_weighted: shapes differ")
    var out = Img(a.rows, a.cols, a.ch)
    var al = Float32(alpha)
    var be = Float32(beta)
    var ga = Float32(gamma)
    for i in range(a.size()):
        out.data[i] = _sat(Float32(a.data[i]) * al + Float32(b.data[i]) * be + ga)
    return out^


def convert_scale_abs(a: Img, alpha: Float64, beta: Float64) -> Img:
    """cv2.convertScaleAbs on uint8: saturate(round(|a*alpha + beta|)) in float32."""
    var out = Img(a.rows, a.cols, a.ch)
    var al = Float32(alpha)
    var be = Float32(beta)
    for i in range(a.size()):
        var v = Float32(a.data[i]) * al + be
        out.data[i] = _sat(-v if v < 0 else v)
    return out^


def apply_color_map_jet(gray: Img) raises -> Img:
    """cv2.applyColorMap(gray, COLORMAP_JET): 1-channel uint8 in, BGR out."""
    var lut = List[UInt8]()
    for tok in String(JET_TEXT).split(" "):
        if tok.byte_length() > 0:
            for c in tok.split(","):
                lut.append(UInt8(atol(String(c))))
    if gray.ch != 1:
        raise Error("apply_color_map: wants a 1-channel image")
    var out = Img(gray.rows, gray.cols, 3)
    for i in range(gray.size()):
        for k in range(3):
            out.data[i * 3 + k] = lut[Int(gray.data[i]) * 3 + k]
    return out^


def blur(a: Img, k: Int) -> Img:
    """cv2.blur(a, (k, k)): normalized box filter, anchor at the centre, BORDER_REFLECT_101, integer sum / k^2 rounded."""
    var lo = k // 2
    var hi = k - 1 - lo
    var tmp = List[Int](length=a.size(), fill=0)
    var out = Img(a.rows, a.cols, a.ch)
    for y in range(a.rows):
        for x in range(a.cols):
            for c in range(a.ch):
                var s = 0
                for d in range(-lo, hi + 1):
                    s += Int(a.at(y, _refl(x + d, a.cols), c))
                tmp[(y * a.cols + x) * a.ch + c] = s
    var inv = 1.0 / Float64(k * k)
    for y in range(a.rows):
        for x in range(a.cols):
            for c in range(a.ch):
                var s = 0
                for d in range(-lo, hi + 1):
                    s += tmp[(_refl(y + d, a.rows) * a.cols + x) * a.ch + c]
                out.data[(y * a.cols + x) * a.ch + c] = UInt8(min(255, rint(Float64(s) * inv)))
    return out^


def _refl(i: Int, n: Int) -> Int:
    """BORDER_REFLECT_101 for any offset (n == 1 maps to 0)."""
    if n == 1:
        return 0
    var j = i
    while j < 0 or j >= n:
        if j < 0:
            j = -j
        if j >= n:
            j = 2 * (n - 1) - j
    return j


def mean(a: Img, c: Int) -> Float64:
    """cv2.mean of channel c."""
    var s = 0.0
    for i in range(a.rows * a.cols):
        s += Float64(a.data[i * a.ch + c])
    return s / Float64(a.rows * a.cols)


def resize_linear(a: Img, dw: Int, dh: Int) -> Img:
    """cv2.resize INTER_LINEAR on uint8 with cv2's fixed point (11-bit weights, horizontal pass to int, vertical pass in the
    SIMD form ((b0*(s0>>4)>>16) + (b1*(s1>>4)>>16) + 2) >> 2). mojo-cv's float path rounds exact ties the other way."""
    var sx = Float64(a.cols) / Float64(dw)
    var sy = Float64(a.rows) / Float64(dh)
    var out = Img(dh, dw, a.ch)
    var xs = List[Int](length=dw, fill=0)
    var xa0 = List[Int](length=dw, fill=0)
    var xa1 = List[Int](length=dw, fill=0)
    for x in range(dw):
        var fx = Float32((Float64(x) + 0.5) * sx - 0.5)
        var ix = Int(fx.__floor__())
        fx -= Float32(ix)
        if ix < 0:
            ix = 0
            fx = 0.0
        if ix >= a.cols - 1:
            ix = a.cols - 1
            fx = 0.0
        xs[x] = ix
        xa0[x] = rint(Float64((Float32(1.0) - fx) * Float32(2048.0)))
        xa1[x] = rint(Float64(fx * Float32(2048.0)))
    for y in range(dh):
        var fy = Float32((Float64(y) + 0.5) * sy - 0.5)
        var iy = Int(fy.__floor__())
        fy -= Float32(iy)
        if iy < 0:
            iy = 0
            fy = 0.0
        if iy >= a.rows - 1:
            iy = a.rows - 1
            fy = 0.0
        var b0 = rint(Float64((Float32(1.0) - fy) * Float32(2048.0)))
        var b1 = rint(Float64(fy * Float32(2048.0)))
        var iy1 = min(iy + 1, a.rows - 1)
        for x in range(dw):
            var x1 = min(xs[x] + 1, a.cols - 1)
            for c in range(a.ch):
                var s0 = Int(a.at(iy, xs[x], c)) * xa0[x] + Int(a.at(iy, x1, c)) * xa1[x]
                var s1 = Int(a.at(iy1, xs[x], c)) * xa0[x] + Int(a.at(iy1, x1, c)) * xa1[x]
                var v = (((b0 * (s0 >> 4)) >> 16) + ((b1 * (s1 >> 4)) >> 16) + 2) >> 2
                out.data[(y * dw + x) * a.ch + c] = UInt8(min(255, max(0, v)))
    return out^
