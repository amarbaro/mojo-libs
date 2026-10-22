# imgproc: filters, colour, geometry and segmentation ops with cv2 5.0 semantics. Border-reading ops work on a
# padded copy of the source, so every inner loop is a plain contiguous SIMD loop over the flattened row
# (pixel i of channel c sits at i * ch + c, so a horizontal tap at dx is a load at offset dx * ch).
from std.sys.info import simd_width_of
from std.math import sqrt, exp, floor, cos, sin, atan2
from max.algorithm import parallelize
from mojocv.mat import Mat, load, save
from mojocv.core import Args, DTS, peek_code

comptime Ptr = MutPointer[_, MutAnyOrigin]
comptime F32 = DType.float32
comptime WF = simd_width_of[DType.float32]()


def rint(x: Float64) -> Int:
    """Round half to even, like cvRound."""
    return Int(x.__round__())


def ptr_of[T: Copyable & Movable](l: List[T]) -> Ptr[T]:
    return Ptr[T](unsafe_from_address=Int(l.unsafe_ptr()))


def bidx(i: Int, n: Int, mode: Int) -> Int:
    """Map i into [0, n): mode 0 reflect101 (cv2 default), 1 replicate, 2 constant (-1 outside)."""
    if i >= 0 and i < n:
        return i
    if mode == 1:
        return 0 if i < 0 else n - 1
    if mode == 2:
        return -1
    if n == 1:
        return 0
    var p = 2 * (n - 1)
    var j = i % p
    return p - j if j >= n else j


def pad[dt: DType](a: Mat[dt], py: Int, px: Int, mode: Int = 0, val: Scalar[dt] = 0) -> Mat[dt]:
    """a with py rows and px columns added on every side."""
    var o = Mat[dt](a.rows + 2 * py, a.cols + 2 * px, a.ch)
    var ch = a.ch
    var pa = a.ptr()
    var po = o.ptr()

    def row(r: Int) {imm}:
        var sr = bidx(r - py, a.rows, mode)
        for c in range(o.cols):
            var sc = bidx(c - px, a.cols, mode)
            for k in range(ch):
                po[unsafe_offset=(r * o.cols + c) * ch + k] = val if (sr < 0 or sc < 0) else pa[unsafe_offset=(sr * a.cols + sc) * ch + k]

    parallelize(row, o.rows)
    return o^


def _ld[sd: DType, w: Int](p: Ptr[Scalar[sd]], at: Int) -> SIMD[F32, w]:
    return p.unsafe_load[width=w](at).cast[F32]()


def _fin[od: DType, w: Int](v: SIMD[F32, w]) -> SIMD[od, w]:
    comptime if od.is_integral():
        return v.__round__().clamp(Scalar[F32](Scalar[od].MIN), Scalar[F32](Scalar[od].MAX)).cast[od]()
    else:
        return v.cast[od]()


def _tap[sd: DType, w: Int](p: Ptr[Scalar[sd]], k: Ptr[Float32], nk: Int, at: Int, step: Int) -> SIMD[F32, w]:
    """sum_t k[t] * p[at + t * step]"""
    var s = SIMD[F32, w](0)
    for t in range(nk):
        s = s + _ld[sd, w](p, at + t * step) * k[t]
    return s


def sepfilter[sd: DType, od: DType](src: Mat[sd], kx: List[Float32], ky: List[Float32], mode: Int = 0) -> Mat[od]:
    """Correlate with the column kernel ky and row kernel kx. Saturates and rounds like cv2 when od is integral."""
    var nx = len(kx)
    var ny = len(ky)
    var p = pad(src, ny // 2, nx // 2, mode)
    var tmp = Mat[F32](p.rows, src.cols, src.ch)
    var o = Mat[od](src.rows, src.cols, src.ch)
    var n = src.cols * src.ch
    var ch = src.ch
    var pp = p.ptr()
    var pt = tmp.ptr()
    var po = o.ptr()
    var pkx = ptr_of(kx)
    var pky = ptr_of(ky)
    var pstride = p.cols * ch

    def hrow(r: Int) {imm}:
        var i = 0
        while i + WF <= n:
            pt.unsafe_store(r * n + i, _tap[sd, WF](pp, pkx, nx, r * pstride + i, ch))
            i += WF
        for j in range(i, n):
            pt.unsafe_store(r * n + j, _tap[sd, 1](pp, pkx, nx, r * pstride + j, ch))

    parallelize(hrow, p.rows)

    def vrow(r: Int) {imm}:
        var i = 0
        while i + WF <= n:
            po.unsafe_store(r * n + i, _fin[od, WF](_tap[F32, WF](pt, pky, ny, r * n + i, n)))
            i += WF
        for j in range(i, n):
            po.unsafe_store(r * n + j, _fin[od, 1](_tap[F32, 1](pt, pky, ny, r * n + j, n)))

    parallelize(vrow, src.rows)
    _ = (p.rows, tmp.rows)
    return o^


def gauss_kernel(n: Int, sigma_in: Float64) -> List[Float32]:
    """cv2.getGaussianKernel (the fixed small-kernel tables when sigma <= 0 and n <= 7)."""
    var k = List[Float32](length=n, fill=0)
    if sigma_in <= 0 and n <= 7 and n % 2 == 1:
        var t: List[Float32]
        if n == 1:
            t = [1.0]
        elif n == 3:
            t = [0.25, 0.5, 0.25]
        elif n == 5:
            t = [0.0625, 0.25, 0.375, 0.25, 0.0625]
        else:
            t = [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]
        return t^
    var sigma = sigma_in if sigma_in > 0 else 0.3 * (Float64(n - 1) * 0.5 - 1) + 0.8
    var s = Float64(0)
    var w = List[Float64](length=n, fill=0)
    for i in range(n):
        var x = Float64(i) - Float64(n - 1) * 0.5
        w[i] = exp(-x * x / (2 * sigma * sigma))
        s += w[i]
    for i in range(n):
        k[i] = Float32(w[i] / s)
    return k^


def deriv_kernel(n: Int, order: Int) -> List[Float32]:
    """cv2.getDerivKernels row: (n - 1 - order) smoothing steps [1 1], then `order` difference steps [-1 1]."""
    var k = List[Float32]()
    k.append(1)
    for step in range(n - 1):
        var nk = List[Float32](length=len(k) + 1, fill=0)
        var a: Float32 = -1 if step >= n - 1 - order else 1
        for i in range(len(k)):
            nk[i] += a * k[i]
            nk[i + 1] += k[i]
        k = nk^
    return k^


def gaussian_blur[dt: DType](src: Mat[dt], ksize: Int, sigma: Float64) -> Mat[dt]:
    var n = ksize
    if n <= 0:
        n = Int(sigma * (3.0 if dt == DType.uint8 else 4.0) * 2 + 1.0 + 0.5) | 1
    var k = gauss_kernel(n, sigma)
    return sepfilter[dt, dt](src, k, k)


def sobel[sd: DType, od: DType](src: Mat[sd], dx: Int, dy: Int, ksize: Int, scale: Float32, mode: Int = 0) -> Mat[od]:
    """ksize -1 selects Scharr."""
    var kx: List[Float32]
    var ky: List[Float32]
    if ksize < 0:
        var s: List[Float32] = [3.0, 10.0, 3.0]
        var d: List[Float32] = [-1.0, 0.0, 1.0]
        kx = d.copy() if dx > 0 else s.copy()
        ky = d^ if dy > 0 else s^
    else:
        kx = deriv_kernel(ksize, dx)
        ky = deriv_kernel(ksize, dy)
    if scale != 1:
        for i in range(len(kx)):
            kx[i] *= scale
    return sepfilter[sd, od](src, kx, ky, mode)


# ---- pyrDown ----------------------------------------------------------------------------------------------


def pyr_down[dt: DType](src: Mat[dt]) -> Mat[dt]:
    """5-tap binomial blur (reflect101), then every second row and column; output ceil(n / 2)."""
    var oc = (src.cols + 1) // 2
    var orow = (src.rows + 1) // 2
    var ch = src.ch
    var p = pad(src, 2, 2)
    var pp = p.ptr()
    var tmp = Mat[F32](p.rows, oc, ch)
    var pt = tmp.ptr()
    var o = Mat[dt](orow, oc, ch)
    var po = o.ptr()
    comptime kk = SIMD[F32, 8](1, 4, 6, 4, 1, 0, 0, 0)

    def hrow(r: Int) {imm}:
        for c in range(oc):
            for k in range(ch):
                var base = (r * p.cols + 2 * c) * ch + k
                var s = Float32(0)
                comptime for t in range(5):
                    s += kk[t] * Float32(pp[unsafe_offset=base + t * ch])
                pt[unsafe_offset=(r * oc + c) * ch + k] = s

    parallelize(hrow, p.rows)
    var n = oc * ch

    def vrow(r: Int) {imm}:
        for i in range(n):
            var s = Float32(0)
            comptime for t in range(5):
                s += kk[t] * pt[unsafe_offset=(2 * r + t) * n + i]
            comptime if dt.is_integral():
                s = floor(s / 256 + 0.5)
            else:
                s = s / 256
            po.unsafe_store(r * n + i, _fin[dt, 1](SIMD[F32, 1](s)))

    parallelize(vrow, orow)
    _ = (p.rows, tmp.rows)
    return o^


# ---- threshold --------------------------------------------------------------------------------------------


def otsu[dt: DType](m: Mat[dt]) -> Int:
    """The threshold cv2 picks for THRESH_OTSU on one 8-bit channel (first maximum of the between-class variance)."""
    var h = List[Float64](length=256, fill=0)
    for v in m.data:
        h[Int(v)] += 1
    var scale = 1.0 / Float64(m.size())
    var mu = Float64(0)
    for i in range(256):
        mu += Float64(i) * h[i] * scale
    var q1 = Float64(0)
    var mu1 = Float64(0)
    var best = Float64(0)
    var val = 0
    for i in range(256):
        var p = h[i] * scale
        mu1 *= q1
        q1 += p
        var q2 = 1.0 - q1
        if min(q1, q2) < 1.1920929e-07 or max(q1, q2) > 1.0 - 1.1920929e-07:
            continue
        mu1 = (mu1 + Float64(i) * p) / q1
        var mu2 = (mu - q1 * mu1) / q2
        var sigma = q1 * q2 * (mu1 - mu2) * (mu1 - mu2)
        if sigma > best:
            best = sigma
            val = i
    return val


def threshold[dt: DType](src: Mat[dt], thresh: Float64, maxval: Float64, kind: Int) -> Mat[dt]:
    """kind: 0 binary, 1 binary_inv, 2 trunc, 3 tozero, 4 tozero_inv (cv2 THRESH_*)."""
    var o = Mat[dt](src.rows, src.cols, src.ch)
    comptime W = simd_width_of[dt]()
    var th: Scalar[dt]
    comptime if dt.is_integral():
        th = Scalar[dt](floor(thresh))
    else:
        th = Scalar[dt](thresh)
    var mx = Scalar[dt](maxval)
    var n = src.cols * src.ch
    var pa = src.ptr()
    var po = o.ptr()

    def row(r: Int) {imm}:
        var i = 0
        while i < n:
            var w = W if i + W <= n else 1
            var x = pa.unsafe_load[width=W](r * n + i) if w == W else SIMD[dt, W](pa[unsafe_offset=r * n + i])
            var gt = x.gt(th)
            var z = SIMD[dt, W](0)
            var v: SIMD[dt, W]
            if kind == 0:
                v = gt.select(SIMD[dt, W](mx), z)
            elif kind == 1:
                v = gt.select(z, SIMD[dt, W](mx))
            elif kind == 2:
                v = gt.select(SIMD[dt, W](th), x)
            elif kind == 3:
                v = gt.select(x, z)
            else:
                v = gt.select(z, x)
            if w == W:
                po.unsafe_store(r * n + i, v)
            else:
                po[unsafe_offset=r * n + i] = v[0]
            i += w

    parallelize(row, src.rows)
    return o^


# ---- integral ---------------------------------------------------------------------------------------------


def integral[sd: DType, od: DType](src: Mat[sd]) -> Mat[od]:
    """(rows + 1) x (cols + 1) summed-area table, zero first row and column, per channel."""
    var ch = src.ch
    var o = Mat[od](src.rows + 1, src.cols + 1, ch)
    var pa = src.ptr()
    var po = o.ptr()
    var stride = o.cols * ch

    def hrow(r: Int) {imm}:
        for k in range(ch):
            var acc = Scalar[od](0)
            for c in range(src.cols):
                acc += Scalar[od](pa[unsafe_offset=(r * src.cols + c) * ch + k])
                po[unsafe_offset=(r + 1) * stride + (c + 1) * ch + k] = acc

    parallelize(hrow, src.rows)
    var chunk = 256
    var nchunk = (stride + chunk - 1) // chunk

    def vcol(t: Int) {imm}:
        for i in range(t * chunk, min((t + 1) * chunk, stride)):
            var acc = Scalar[od](0)
            for r in range(1, o.rows):
                acc += po[unsafe_offset=r * stride + i]
                po[unsafe_offset=r * stride + i] = acc

    parallelize(vcol, nchunk)
    return o^


# ---- morphology -------------------------------------------------------------------------------------------


def strel(shape: Int, k: Int) -> List[Int]:
    """cv2.getStructuringElement runs as (dy, x1, x2) triples relative to the anchor k // 2.
    shape 0 rect, 1 cross, 2 ellipse."""
    var out = List[Int]()
    var a = k // 2
    for i in range(k):
        var x1 = 0
        var x2 = k - 1
        if shape == 1:
            x1 = a if i != a else 0
            x2 = a if i != a else k - 1
        elif shape == 2:
            var r = a
            var dy = i - r
            if abs(dy) <= r:
                var inv = 1.0 / Float64(r * r) if r > 0 else 0.0
                var dx = Int(Float64(a) * sqrt(Float64(r * r - dy * dy) * inv) + 0.5) if r > 0 else 0
                x1 = max(a - dx, 0)
                x2 = min(a + dx + 1, k) - 1
            else:
                x1 = 1
                x2 = 0
        if x1 <= x2:
            out.append(i - a)
            out.append(x1 - a)
            out.append(x2 - a)
    return out^


def morph[is_min: Bool, dt: DType](src: Mat[dt], shape: Int, k: Int, iters: Int) -> Mat[dt]:
    """erode (is_min) or dilate with a k x k structuring element, borders ignored as cv2 does."""
    var runs = strel(shape, k)
    var r = k // 2
    var ch = src.ch
    comptime W = simd_width_of[dt]()
    comptime ident = Scalar[dt].MAX if is_min else Scalar[dt].MIN
    var cur = Mat[dt](copy=src)
    var n = src.cols * ch
    for _ in range(iters):
        var p = pad(cur, r, r, 2, ident)
        var pp = p.ptr()
        var o = Mat[dt](src.rows, src.cols, ch)
        var po = o.ptr()
        var pr = ptr_of(runs)
        var nr = len(runs) // 3
        var pstride = p.cols * ch

        def row(y: Int) {imm}:
            var i = 0
            while i < n:
                var w = W if i + W <= n else 1
                var acc = SIMD[dt, W](ident)
                for q in range(nr):
                    var base = (y + r + pr[unsafe_offset=3 * q]) * pstride + r * ch + i
                    for dx in range(pr[unsafe_offset=3 * q + 1], pr[unsafe_offset=3 * q + 2] + 1):
                        var v = pp.unsafe_load[width=W](base + dx * ch) if w == W else SIMD[dt, W](pp[unsafe_offset=base + dx * ch])
                        comptime if is_min:
                            acc = min(acc, v)
                        else:
                            acc = max(acc, v)
                if w == W:
                    po.unsafe_store(y * n + i, acc)
                else:
                    po[unsafe_offset=y * n + i] = acc[0]
                i += w

        parallelize(row, src.rows)
        _ = (p.rows, runs.__len__())
        cur = o^
    return cur^


# ---- cvtColor ---------------------------------------------------------------------------------------------

def cvt_code(name: String) raises -> Int:
    var names: List[String] = ["bgr2gray", "rgb2gray", "gray2bgr", "bgr2rgb", "bgr2hsv", "hsv2bgr", "bgr2ycrcb", "ycrcb2bgr"]
    for i in range(len(names)):
        if names[i] == name:
            return i
    raise Error("mojocv: cvtColor code " + name)


def _sat8(v: Float32) -> UInt8:
    return UInt8(min(max(floor(v + 0.5), 0), 255))


def cvt_color[dt: DType](src: Mat[dt], code: Int) raises -> Mat[dt]:
    """code indexes CODES. 8-bit images use cv2's integer arithmetic; float images use its float formulas."""
    var oc = 1 if (code == 0 or code == 1) else 3
    var ic = 1 if code == 2 else 3
    if src.ch != ic:
        raise Error("mojocv: cvtColor code " + String(code) + " wants " + String(ic) + " channels")
    var o = Mat[dt](src.rows, src.cols, oc)
    var pa = src.ptr()
    var po = o.ptr()
    var npx = src.cols

    def row(r: Int) {imm}:
        for c in range(npx):
            var i = (r * npx + c) * ic
            var j = (r * npx + c) * oc
            comptime if dt == DType.uint8:
                var qa = pa.unsafe_bitcast[UInt8]()
                var qo = po.unsafe_bitcast[UInt8]()
                var x0 = Int(qa[unsafe_offset=i])
                var x1 = Int(qa[unsafe_offset=i + 1]) if ic == 3 else 0
                var x2 = Int(qa[unsafe_offset=i + 2]) if ic == 3 else 0
                if code == 0 or code == 1:
                    var b = x0 if code == 0 else x2
                    var rr = x2 if code == 0 else x0
                    qo[unsafe_offset=j] = UInt8((b * 3735 + x1 * 19235 + rr * 9798 + 16384) >> 15)
                elif code == 2:
                    qo[unsafe_offset=j] = UInt8(x0)
                    qo[unsafe_offset=j + 1] = UInt8(x0)
                    qo[unsafe_offset=j + 2] = UInt8(x0)
                elif code == 3:
                    qo[unsafe_offset=j] = UInt8(x2)
                    qo[unsafe_offset=j + 1] = UInt8(x1)
                    qo[unsafe_offset=j + 2] = UInt8(x0)
                elif code == 4:
                    var v = max(x0, max(x1, x2))
                    var diff = v - min(x0, min(x1, x2))
                    var sdiv = Int(floor(Float64(255 << 12) / Float64(v) + 0.5)) if v > 0 else 0
                    var hdiv = Int(floor(Float64(180 << 12) / Float64(6 * diff) + 0.5)) if diff > 0 else 0
                    var h: Int
                    if v == x2:
                        h = x1 - x0
                    elif v == x1:
                        h = x0 - x2 + 2 * diff
                    else:
                        h = x2 - x1 + 4 * diff
                    h = (h * hdiv + (1 << 11)) >> 12
                    h += 180 if h < 0 else 0
                    qo[unsafe_offset=j] = UInt8(h)
                    qo[unsafe_offset=j + 1] = UInt8((diff * sdiv + (1 << 11)) >> 12)
                    qo[unsafe_offset=j + 2] = UInt8(v)
                elif code == 5:
                    var h = Float32(x0) * (6.0 / 180.0)
                    var s = Float32(x1) * (1.0 / 255.0)
                    var v = Float32(x2) * (1.0 / 255.0)
                    var sec = Int(floor(h))
                    var f = h - Float32(sec)
                    sec = sec % 6
                    var t0 = v
                    var t1 = v * (1 - s)
                    var t2 = v * (1 - s * f)
                    var t3 = v * (1 - s * (1 - f))
                    var tab = SIMD[F32, 4](t0, t1, t2, t3)
                    var bi = 0
                    var gi = 0
                    var ri = 0
                    if sec == 0:
                        bi, gi, ri = 1, 3, 0
                    elif sec == 1:
                        bi, gi, ri = 1, 0, 2
                    elif sec == 2:
                        bi, gi, ri = 3, 0, 1
                    elif sec == 3:
                        bi, gi, ri = 0, 2, 1
                    elif sec == 4:
                        bi, gi, ri = 0, 1, 3
                    else:
                        bi, gi, ri = 2, 1, 0
                    qo[unsafe_offset=j] = _sat8(tab[bi] * 255)
                    qo[unsafe_offset=j + 1] = _sat8(tab[gi] * 255)
                    qo[unsafe_offset=j + 2] = _sat8(tab[ri] * 255)
                elif code == 6:
                    var y = (x0 * 3735 + x1 * 19235 + x2 * 9798 + 16384) >> 15
                    var dl = (128 << 14) + (1 << 13)
                    qo[unsafe_offset=j] = UInt8(y)
                    qo[unsafe_offset=j + 1] = UInt8(max(0, min(255, ((x2 - y) * 11682 + dl) >> 14)))
                    qo[unsafe_offset=j + 2] = UInt8(max(0, min(255, ((x0 - y) * 9241 + dl) >> 14)))
                else:
                    var cr = Float32(x1 - 128)
                    var cb = Float32(x2 - 128)
                    qo[unsafe_offset=j + 2] = _sat8(Float32(x0) + 1.403 * cr)
                    qo[unsafe_offset=j + 1] = _sat8(Float32(x0) - 0.714 * cr - 0.344 * cb)
                    qo[unsafe_offset=j] = _sat8(Float32(x0) + 1.773 * cb)
            else:
                var x0 = pa[unsafe_offset=i]
                if code == 0 or code == 1:
                    var b = x0 if code == 0 else pa[unsafe_offset=i + 2]
                    var rr = pa[unsafe_offset=i + 2] if code == 0 else x0
                    po[unsafe_offset=j] = Scalar[dt](0.114) * b + Scalar[dt](0.587) * pa[unsafe_offset=i + 1] + Scalar[dt](0.299) * rr
                elif code == 2:
                    for k in range(3):
                        po[unsafe_offset=j + k] = x0
                elif code == 3:
                    po[unsafe_offset=j] = pa[unsafe_offset=i + 2]
                    po[unsafe_offset=j + 1] = pa[unsafe_offset=i + 1]
                    po[unsafe_offset=j + 2] = x0

    parallelize(row, src.rows)
    return o^


# ---- resize -----------------------------------------------------------------------------------------------


def cubic_w(x: Float64) -> SIMD[DType.float64, 4]:
    """cv2 bicubic weights for the taps -1, 0, 1, 2 around a sample at fraction x, A = -0.75."""
    comptime A = -0.75
    var w0 = ((A * (x + 1) - 5 * A) * (x + 1) + 8 * A) * (x + 1) - 4 * A
    var w1 = ((A + 2) * x - (A + 3)) * x * x + 1
    var w2 = ((A + 2) * (1 - x) - (A + 3)) * (1 - x) * (1 - x) + 1
    return SIMD[DType.float64, 4](w0, w1, w2, 1.0 - w0 - w1 - w2)


def lanczos_w(x: Float64) -> SIMD[DType.float64, 8]:
    """cv2 Lanczos4 weights for the taps -3 .. 4 around a sample at fraction x."""
    var c = SIMD[DType.float64, 8](0)
    if x < 1.1920929e-07:
        c[3] = 1
        return c
    comptime s45 = 0.70710678118654752440084436210485
    var cs = SIMD[DType.float64, 16](1, 0, -s45, -s45, 0, 1, s45, -s45, -1, 0, s45, s45, 0, -1, -s45, s45)
    var pi = 3.14159265358979323846
    var y0 = -(x + 3) * pi * 0.25
    var s0 = sin(y0)
    var c0 = cos(y0)
    var sum = Float64(0)
    for i in range(8):
        var y = -(x + 3 - Float64(i)) * pi * 0.25
        c[i] = Float64(Float32((cs[2 * i] * s0 + cs[2 * i + 1] * c0) / (y * y)))
        sum += c[i]
    return c * Float64(Float32(1.0 / sum))


struct Taps(Movable):
    """For each output index: `n` source indices (clamped) and weights."""

    var n: Int
    var idx: List[Int]
    var w: List[Float32]

    def __init__(out self, ssize: Int, dsize: Int, scale: Float64, kind: Int):
        """kind 0 nearest, 1 linear, 2 cubic, 3 lanczos4"""
        self.n = 1 if kind == 0 else (2 if kind == 1 else (4 if kind == 2 else 8))
        self.idx = List[Int](length=dsize * self.n, fill=0)
        self.w = List[Float32](length=dsize * self.n, fill=0)
        for d in range(dsize):
            if kind == 0:
                self.idx[d] = min(Int(floor(Float64(d) * scale)), ssize - 1)
                self.w[d] = 1
                continue
            var f = (Float64(d) + 0.5) * scale - 0.5
            var s = Int(floor(f))
            f -= Float64(s)
            if kind == 1 and s < 0:
                f = 0
                s = 0
            var half = self.n // 2 - 1
            var ww = SIMD[DType.float64, 8](0)
            if kind == 1:
                ww[0] = 1 - f
                ww[1] = f
            elif kind == 2:
                var c = cubic_w(f)
                for t in range(4):
                    ww[t] = c[t]
            else:
                ww = lanczos_w(f)
            for t in range(self.n):
                self.idx[d * self.n + t] = min(max(s - half + t, 0), ssize - 1)
                self.w[d * self.n + t] = Float32(ww[t])


def resize[dt: DType](src: Mat[dt], dw: Int, dh: Int, kind: Int) -> Mat[dt]:
    var tx = Taps(src.cols, dw, Float64(src.cols) / Float64(dw), kind)
    var ty = Taps(src.rows, dh, Float64(src.rows) / Float64(dh), kind)
    var ch = src.ch
    var need = List[Bool](length=src.rows, fill=False)
    for i in range(len(ty.idx)):
        need[ty.idx[i]] = True
    var tmp = Mat[F32](src.rows, dw, ch)
    var o = Mat[dt](dh, dw, ch)
    var pa = src.ptr()
    var pt = tmp.ptr()
    var po = o.ptr()
    var pix = ptr_of(tx.idx)
    var pwx = ptr_of(tx.w)
    var piy = ptr_of(ty.idx)
    var pwy = ptr_of(ty.w)
    var pneed = ptr_of(need)
    var nx = tx.n
    var ny = ty.n
    var n = dw * ch

    def hrow(r: Int) {imm}:
        if not pneed[unsafe_offset=r]:
            return
        for d in range(dw):
            for k in range(ch):
                var s = Float32(0)
                for t in range(nx):
                    s += pwx[unsafe_offset=d * nx + t] * Float32(pa[unsafe_offset=(r * src.cols + pix[unsafe_offset=d * nx + t]) * ch + k])
                pt[unsafe_offset=(r * dw + d) * ch + k] = s

    parallelize(hrow, src.rows)

    def vrow(r: Int) {imm}:
        var i = 0
        while i < n:
            var w = WF if i + WF <= n else 1
            var acc = SIMD[F32, WF](0)
            for t in range(ny):
                var row = piy[unsafe_offset=r * ny + t]
                var x = pt.unsafe_load[width=WF](row * n + i) if w == WF else SIMD[F32, WF](pt[unsafe_offset=row * n + i])
                acc += x * pwy[unsafe_offset=r * ny + t]
            var z = _fin[dt, WF](acc)
            if w == WF:
                po.unsafe_store(r * n + i, z)
            else:
                po[unsafe_offset=r * n + i] = z[0]
            i += w

    parallelize(vrow, dh)
    _ = (tmp.rows, tx.n, ty.n, len(need))
    return o^


# ---- warpAffine / remap -----------------------------------------------------------------------------------
# cv2 5.0 interpolates at the exact float position (the 1/32 fixed-point tables are gone), so one sampler serves both.


def border_px[dt: DType](src: Mat[dt], y: Int, x: Int, k: Int, mode: Int, bval: Scalar[dt]) -> Scalar[dt]:
    var yy = bidx(y, src.rows, mode)
    var xx = bidx(x, src.cols, mode)
    if yy < 0 or xx < 0:
        return bval
    return src.data[(yy * src.cols + xx) * src.ch + k]


def sample[dt: DType](src: Mat[dt], fx: Float64, fy: Float64, kind: Int, mode: Int, bval: Scalar[dt], dst: Ptr[Scalar[dt]]):
    """Write the interpolated pixel at (fx, fy) (kind 0 nearest, 1 linear, 2 cubic) to dst[0 .. ch)."""
    var n = 1 if kind == 0 else (2 if kind == 1 else 4)
    var off = 0 if kind != 2 else 1
    var sx = Int(floor(fx + 0.5)) if kind == 0 else Int(floor(fx))
    var sy = Int(floor(fy + 0.5)) if kind == 0 else Int(floor(fy))
    var wx = SIMD[DType.float64, 4](1, 0, 0, 0)
    var wy = SIMD[DType.float64, 4](1, 0, 0, 0)
    if kind == 1:
        wx = SIMD[DType.float64, 4](1 - (fx - Float64(sx)), fx - Float64(sx), 0, 0)
        wy = SIMD[DType.float64, 4](1 - (fy - Float64(sy)), fy - Float64(sy), 0, 0)
    elif kind == 2:
        wx = cubic_w(fx - Float64(sx))
        wy = cubic_w(fy - Float64(sy))
    for k in range(src.ch):
        var acc = Float64(0)
        for a in range(n):
            for b in range(n):
                acc += wy[a] * wx[b] * Float64(border_px(src, sy + a - off, sx + b - off, k, mode, bval))
        comptime if dt.is_integral():
            acc = max(Float64(Scalar[dt].MIN), min(Float64(Scalar[dt].MAX), acc.__round__()))
        dst[unsafe_offset=k] = Scalar[dt](acc)


def warp_affine[dt: DType](src: Mat[dt], m: List[Float64], dw: Int, dh: Int, kind: Int, mode: Int, bval: Float64) -> Mat[dt]:
    """m is the inverse map (dst -> src) as a 2 x 3 matrix."""
    var o = Mat[dt](dh, dw, src.ch)
    var pm = ptr_of(m)
    var po = o.ptr()
    var bv = Scalar[dt](bval)

    def row(y: Int) {imm}:
        for x in range(dw):
            var fx = pm[unsafe_offset=0] * Float64(x) + pm[unsafe_offset=1] * Float64(y) + pm[unsafe_offset=2]
            var fy = pm[unsafe_offset=3] * Float64(x) + pm[unsafe_offset=4] * Float64(y) + pm[unsafe_offset=5]
            sample(src, fx, fy, kind, mode, bv, po + (y * dw + x) * src.ch)

    parallelize(row, dh)
    _ = len(m)
    return o^


def remap[dt: DType](src: Mat[dt], mx: Mat[F32], my: Mat[F32], kind: Int, mode: Int, bval: Float64) -> Mat[dt]:
    var o = Mat[dt](mx.rows, mx.cols, src.ch)
    var po = o.ptr()
    var bv = Scalar[dt](bval)
    var pmx = mx.ptr()
    var pmy = my.ptr()

    def row(y: Int) {imm}:
        for x in range(mx.cols):
            var i = y * mx.cols + x
            sample(src, Float64(pmx[unsafe_offset=i]), Float64(pmy[unsafe_offset=i]), kind, mode, bv, po + i * src.ch)

    parallelize(row, mx.rows)
    _ = (mx.rows, my.rows)
    return o^


def blob[dt: DType](src: Mat[dt], dw: Int, dh: Int, scale: Float32, mean: List[Float32], swap: Bool) -> Mat[F32]:
    """cv2.dnn.blobFromImage with a plain resize: planes laid out as (channel * h, w), float32."""
    var r = resize(src, dw, dh, 1) if (dw != src.cols or dh != src.rows) else Mat[dt](copy=src)
    var o = Mat[F32](r.ch * dh, dw, 1)
    for c in range(r.ch):
        var sc = (r.ch - 1 - c) if (swap and r.ch == 3) else c
        for y in range(dh):
            for x in range(dw):
                o.data[(c * dh + y) * dw + x] = (Float32(r.data[(y * dw + x) * r.ch + sc]) - mean[c]) * scale
    return o^


# ---- CLI --------------------------------------------------------------------------------------------------


def run_dt[dt: DType](mut a: Args) raises -> Bool:
    var m = load[dt](a.ins[0])
    if a.op == "GaussianBlur":
        var o = Mat[dt](0, 0)
        while a.again():
            o = gaussian_blur(m, a.i("ksize", 5), a.f("sigma", 0.0))
        save(o, a.out)
    elif a.op == "pyrDown":
        var o = Mat[dt](0, 0)
        while a.again():
            o = pyr_down(m)
        save(o, a.out)
    elif a.op == "Sobel":
        comptime if dt == DType.uint8:
            var o = Mat[DType.int16](0, 0)
            while a.again():
                o = sobel[dt, DType.int16](m, a.i("dx", 1), a.i("dy", 0), a.i("ksize", 3), Float32(a.f("scale", 1.0)))
            save(o, a.out)
        else:
            var o = Mat[dt](0, 0)
            while a.again():
                o = sobel[dt, dt](m, a.i("dx", 1), a.i("dy", 0), a.i("ksize", 3), Float32(a.f("scale", 1.0)))
            save(o, a.out)
    elif a.op == "resize":
        var o = Mat[dt](0, 0)
        var kind = a.i("interp", 1)
        while a.again():
            o = resize(m, a.i("w", m.cols), a.i("h", m.rows), kind)
        save(o, a.out)
    elif a.op == "warpAffine":
        var f = a.fl("M", [1.0, 0.0, 0.0, 0.0, 1.0, 0.0])
        var inv = f.copy()
        if a.i("inv", 0) == 0:
            var d = f[0] * f[4] - f[1] * f[3]
            d = 1.0 / d if d != 0 else 0.0
            inv = [f[4] * d, -f[1] * d, 0.0, -f[3] * d, f[0] * d, 0.0]
            inv[2] = -inv[0] * f[2] - inv[1] * f[5]
            inv[5] = -inv[3] * f[2] - inv[4] * f[5]
        var o = Mat[dt](0, 0)
        while a.again():
            o = warp_affine(m, inv, a.i("w", m.cols), a.i("h", m.rows), a.i("interp", 1), a.i("border", 2), a.f("bval", 0.0))
        save(o, a.out)
    elif a.op == "remap":
        var mx = load[F32](a.ins[1])
        var my = load[F32](a.ins[2])
        var o = Mat[dt](0, 0)
        while a.again():
            o = remap(m, mx, my, a.i("interp", 1), a.i("border", 2), a.f("bval", 0.0))
        save(o, a.out)
    elif a.op == "blobFromImage":
        var mean = a.fl("mean", [0.0, 0.0, 0.0])
        var mf = List[Float32]()
        for v in mean:
            mf.append(Float32(v))
        var o = Mat[F32](0, 0)
        while a.again():
            o = blob(m, a.i("w", m.cols), a.i("h", m.rows), Float32(a.f("scale", 1.0)), mf, a.i("swap", 0) == 1)
        save(o, a.out)
    elif a.op == "threshold":
        var th = a.f("thresh", 127.0)
        var o = Mat[dt](0, 0)
        comptime if dt == DType.uint8:
            if a.i("otsu", 0) == 1:
                th = Float64(otsu(m))
        while a.again():
            o = threshold(m, th, a.f("maxval", 255.0), a.i("type", 0))
        save(o, a.out)
        var t = Mat[DType.float64](1, 1)
        t.set(0, 0, 0, Float64(floor(th)) if dt.is_integral() else th)
        save(t, a.out + ".1")
    elif a.op == "integral":
        comptime if dt == DType.uint8:
            var o = Mat[DType.int32](0, 0)
            while a.again():
                o = integral[dt, DType.int32](m)
            save(o, a.out)
        else:
            var o = Mat[DType.float64](0, 0)
            while a.again():
                o = integral[dt, DType.float64](m)
            save(o, a.out)
    elif a.op == "erode" or a.op == "dilate":
        var o = Mat[dt](0, 0)
        while a.again():
            if a.op == "erode":
                o = morph[True, dt](m, a.i("shape", 0), a.i("ksize", 3), a.i("iters", 1))
            else:
                o = morph[False, dt](m, a.i("shape", 0), a.i("ksize", 3), a.i("iters", 1))
        save(o, a.out)
    elif a.op == "cvtColor":
        var code = cvt_code(a.s("code", ""))
        var o = Mat[dt](0, 0)
        while a.again():
            o = cvt_color(m, code)
        save(o, a.out)
    else:
        return False
    return True


def run(mut a: Args) raises -> Bool:
    if not (a.op in ["GaussianBlur", "pyrDown", "Sobel", "threshold", "integral", "erode", "dilate", "cvtColor", "resize", "warpAffine", "remap", "blobFromImage"]):
        return False
    var code = peek_code(a.ins[0])
    comptime for i in range(2):
        if code == i:
            return run_dt[DTS[i]](a)
    return False
