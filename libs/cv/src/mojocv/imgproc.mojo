# imgproc: filters, colour, geometry and segmentation ops with cv2 5.0 semantics. Border-reading ops work on a
# padded copy of the source, so every inner loop is a plain contiguous SIMD loop over the flattened row
# (pixel i of channel c sits at i * ch + c, so a horizontal tap at dx is a load at offset dx * ch).
from std.sys.info import simd_width_of
from std.math import sqrt, exp, floor, cos, sin, atan2
from mojocv.mat import Mat, load, save
from mojocv.core import Args, DTS, peek_code, par
from std.math import log as log_

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
    var ostride = o.cols * ch
    var astride = a.cols * ch

    def row(r: Int) {imm}:
        var sr = bidx(r - py, a.rows, mode)
        var dst = po + r * ostride
        if sr < 0:
            for i in range(ostride):
                dst[unsafe_offset=i] = val
            return
        var src = pa + sr * astride
        for i in range(astride):
            dst[unsafe_offset=px * ch + i] = src[unsafe_offset=i]
        for c in range(px):
            var lc = bidx(c - px, a.cols, mode)
            var rc = bidx(a.cols + c, a.cols, mode)
            for k in range(ch):
                dst[unsafe_offset=c * ch + k] = val if lc < 0 else src[unsafe_offset=lc * ch + k]
                dst[unsafe_offset=(px + a.cols + c) * ch + k] = val if rc < 0 else src[unsafe_offset=rc * ch + k]

    par(row, o.rows)
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

    par(hrow, p.rows)

    def vrow(r: Int) {imm}:
        var i = 0
        while i + WF <= n:
            po.unsafe_store(r * n + i, _fin[od, WF](_tap[F32, WF](pt, pky, ny, r * n + i, n)))
            i += WF
        for j in range(i, n):
            po.unsafe_store(r * n + j, _fin[od, 1](_tap[F32, 1](pt, pky, ny, r * n + j, n)))

    par(vrow, src.rows)
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

    par(hrow, p.rows)
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

    par(vrow, orow)
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
        var base = r * n
        var i = 0
        while i + W <= n:
            var x = pa.unsafe_load[width=W](base + i)
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
            po.unsafe_store(base + i, v)
            i += W
        for j in range(i, n):
            var x = pa[unsafe_offset=base + j]
            var gt = x > th
            var v: Scalar[dt]
            if kind == 0:
                v = mx if gt else Scalar[dt](0)
            elif kind == 1:
                v = Scalar[dt](0) if gt else mx
            elif kind == 2:
                v = th if gt else x
            elif kind == 3:
                v = x if gt else Scalar[dt](0)
            else:
                v = Scalar[dt](0) if gt else x
            po[unsafe_offset=base + j] = v

    par(row, src.rows)
    return o^


# ---- integral ---------------------------------------------------------------------------------------------


def integral[sd: DType, od: DType](src: Mat[sd]) -> Mat[od]:
    """(rows + 1) x (cols + 1) summed-area table, zero first row and column, per channel."""
    var ch = src.ch
    var o = Mat[od](src.rows + 1, src.cols + 1, ch, False)
    var pa = src.ptr()
    var po = o.ptr()
    var stride = o.cols * ch
    # zero first row and first column (rest is overwritten)
    for i in range(stride):
        po[unsafe_offset=i] = Scalar[od](0)
    for r in range(o.rows):
        for k in range(ch):
            po[unsafe_offset=r * stride + k] = Scalar[od](0)

    def hrow(r: Int) {imm}:
        for k in range(ch):
            var acc = Scalar[od](0)
            var psrc = pa + (r * src.cols) * ch + k
            var pdst = po + (r + 1) * stride + ch + k
            for c in range(src.cols):
                acc += Scalar[od](psrc[unsafe_offset=c * ch])
                pdst[unsafe_offset=c * ch] = acc

    par(hrow, src.rows)

    comptime W = simd_width_of[od]()
    for r in range(1, o.rows):
        var base = r * stride
        var prev = (r - 1) * stride
        var i = 0
        while i + W <= stride:
            var cur = po.unsafe_load[width=W](base + i)
            var pr = po.unsafe_load[width=W](prev + i)
            po.unsafe_store(base + i, cur + pr)
            i += W
        for j in range(i, stride):
            po[unsafe_offset=base + j] += po[unsafe_offset=prev + j]

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
    var cur = Mat[dt](0, 0)
    var n = src.cols * ch
    for it in range(iters):
        var p = pad(src, r, r, 2, ident) if it == 0 else pad(cur, r, r, 2, ident)
        var pp = p.ptr()
        var o = Mat[dt](src.rows, src.cols, ch)
        var po = o.ptr()
        var pstride = p.cols * ch
        if shape == 0:
            # a rectangle is separable: min over the row window, then over the column window
            var tmp = Mat[dt](p.rows, src.cols, ch)
            var pt = tmp.ptr()

            def hrow(y: Int) {imm}:
                var i = 0
                while i + W <= n:
                    var acc = SIMD[dt, W](ident)
                    for dx in range(-r, r + 1):
                        var v = pp.unsafe_load[width=W](y * pstride + r * ch + i + dx * ch)
                        comptime if is_min:
                            acc = min(acc, v)
                        else:
                            acc = max(acc, v)
                    pt.unsafe_store(y * n + i, acc)
                    i += W
                for ii in range(i, n):
                    var acc = ident
                    for dx in range(-r, r + 1):
                        var v = pp[unsafe_offset=y * pstride + r * ch + ii + dx * ch]
                        comptime if is_min:
                            if v < acc:
                                acc = v
                        else:
                            if v > acc:
                                acc = v
                    pt[unsafe_offset=y * n + ii] = acc

            def hband(b: Int) {imm}:
                var r0 = b * 8
                var r1 = r0 + 8
                if r1 > p.rows:
                    r1 = p.rows
                for y in range(r0, r1):
                    var i = 0
                    while i + W <= n:
                        var acc = SIMD[dt, W](ident)
                        for dx in range(-r, r + 1):
                            var v = pp.unsafe_load[width=W](y * pstride + r * ch + i + dx * ch)
                            comptime if is_min:
                                acc = min(acc, v)
                            else:
                                acc = max(acc, v)
                        pt.unsafe_store(y * n + i, acc)
                        i += W
                    for ii in range(i, n):
                        var acc = ident
                        for dx in range(-r, r + 1):
                            var v = pp[unsafe_offset=y * pstride + r * ch + ii + dx * ch]
                            comptime if is_min:
                                if v < acc:
                                    acc = v
                            else:
                                if v > acc:
                                    acc = v
                        pt[unsafe_offset=y * n + ii] = acc

            par(hrow, p.rows)

            def vband(b: Int) {imm}:
                var r0 = b * 8
                var r1 = r0 + 8
                if r1 > src.rows:
                    r1 = src.rows
                for y in range(r0, r1):
                    var i = 0
                    while i + W <= n:
                        var acc = SIMD[dt, W](ident)
                        for dy in range(0, 2 * r + 1):
                            var v = pt.unsafe_load[width=W]((y + dy) * n + i)
                            comptime if is_min:
                                acc = min(acc, v)
                            else:
                                acc = max(acc, v)
                        po.unsafe_store(y * n + i, acc)
                        i += W
                    for ii in range(i, n):
                        var acc = ident
                        for dy in range(0, 2 * r + 1):
                            var v = pt[unsafe_offset=(y + dy) * n + ii]
                            comptime if is_min:
                                if v < acc:
                                    acc = v
                            else:
                                if v > acc:
                                    acc = v
                        po[unsafe_offset=y * n + ii] = acc

            par(vband, (src.rows + 7) // 8)
            _ = (p.rows, tmp.rows)
        else:
            var pr = ptr_of(runs)
            var nr = len(runs) // 3

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

            par(row, src.rows)
            _ = (p.rows, len(runs))
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
        comptime if dt == DType.uint8:
            if code == 3:
                var base = r * npx * 3
                var qa = pa.unsafe_bitcast[UInt8]()
                var qo = po.unsafe_bitcast[UInt8]()
                var c = 0
                while c + 8 < npx:
                    var v = (qa + base + c * 3).unsafe_load[width=32]()
                    var s = v.shuffle[2,1,0,5,4,3,8,7,6,11,10,9,14,13,12,17,16,15,20,19,18,23,22,21,24,25,26,27,28,29,30,31]()
                    (qo + base + c * 3).unsafe_store[width=32](s)
                    c += 8
                for cc in range(c, npx):
                    var i = base + cc * 3
                    qo[i] = qa[i + 2]
                    qo[i + 1] = qa[i + 1]
                    qo[i + 2] = qa[i]
                return
        comptime if dt == DType.uint8:
            if code == 0 or code == 1:
                var base = r * npx * 3
                var qa = pa.unsafe_bitcast[UInt8]()
                var qo = po.unsafe_bitcast[UInt8]()
                var c = 0
                if code == 0:
                    while c + 16 <= npx:
                        var v0 = (qa + base + c * 3).unsafe_load[width=32]()
                        var blue0 = SIMD[DType.uint8, 8](v0[0], v0[3], v0[6], v0[9], v0[12], v0[15], v0[18], v0[21])
                        var green0 = SIMD[DType.uint8, 8](v0[1], v0[4], v0[7], v0[10], v0[13], v0[16], v0[19], v0[22])
                        var red0 = SIMD[DType.uint8, 8](v0[2], v0[5], v0[8], v0[11], v0[14], v0[17], v0[20], v0[23])
                        var y0 = (blue0.cast[DType.int32]() * 3735 + green0.cast[DType.int32]() * 19235 + red0.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c, y0.cast[DType.uint8]())
                        var v1 = (qa + base + (c + 8) * 3).unsafe_load[width=32]()
                        var blue1 = SIMD[DType.uint8, 8](v1[0], v1[3], v1[6], v1[9], v1[12], v1[15], v1[18], v1[21])
                        var green1 = SIMD[DType.uint8, 8](v1[1], v1[4], v1[7], v1[10], v1[13], v1[16], v1[19], v1[22])
                        var red1 = SIMD[DType.uint8, 8](v1[2], v1[5], v1[8], v1[11], v1[14], v1[17], v1[20], v1[23])
                        var y1 = (blue1.cast[DType.int32]() * 3735 + green1.cast[DType.int32]() * 19235 + red1.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c + 8, y1.cast[DType.uint8]())
                        c += 16
                    while c + 8 <= npx:
                        var v = (qa + base + c * 3).unsafe_load[width=32]()
                        var blue = SIMD[DType.uint8, 8](v[0], v[3], v[6], v[9], v[12], v[15], v[18], v[21])
                        var green = SIMD[DType.uint8, 8](v[1], v[4], v[7], v[10], v[13], v[16], v[19], v[22])
                        var red = SIMD[DType.uint8, 8](v[2], v[5], v[8], v[11], v[14], v[17], v[20], v[23])
                        var y = (blue.cast[DType.int32]() * 3735 + green.cast[DType.int32]() * 19235 + red.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c, y.cast[DType.uint8]())
                        c += 8
                else:
                    while c + 16 <= npx:
                        var v0 = (qa + base + c * 3).unsafe_load[width=32]()
                        var blue0 = SIMD[DType.uint8, 8](v0[2], v0[5], v0[8], v0[11], v0[14], v0[17], v0[20], v0[23])
                        var green0 = SIMD[DType.uint8, 8](v0[1], v0[4], v0[7], v0[10], v0[13], v0[16], v0[19], v0[22])
                        var red0 = SIMD[DType.uint8, 8](v0[0], v0[3], v0[6], v0[9], v0[12], v0[15], v0[18], v0[21])
                        var y0 = (blue0.cast[DType.int32]() * 3735 + green0.cast[DType.int32]() * 19235 + red0.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c, y0.cast[DType.uint8]())
                        var v1 = (qa + base + (c + 8) * 3).unsafe_load[width=32]()
                        var blue1 = SIMD[DType.uint8, 8](v1[2], v1[5], v1[8], v1[11], v1[14], v1[17], v1[20], v1[23])
                        var green1 = SIMD[DType.uint8, 8](v1[1], v1[4], v1[7], v1[10], v1[13], v1[16], v1[19], v1[22])
                        var red1 = SIMD[DType.uint8, 8](v1[0], v1[3], v1[6], v1[9], v1[12], v1[15], v1[18], v1[21])
                        var y1 = (blue1.cast[DType.int32]() * 3735 + green1.cast[DType.int32]() * 19235 + red1.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c + 8, y1.cast[DType.uint8]())
                        c += 16
                    while c + 8 <= npx:
                        var v = (qa + base + c * 3).unsafe_load[width=32]()
                        var blue = SIMD[DType.uint8, 8](v[2], v[5], v[8], v[11], v[14], v[17], v[20], v[23])
                        var green = SIMD[DType.uint8, 8](v[1], v[4], v[7], v[10], v[13], v[16], v[19], v[22])
                        var red = SIMD[DType.uint8, 8](v[0], v[3], v[6], v[9], v[12], v[15], v[18], v[21])
                        var y = (blue.cast[DType.int32]() * 3735 + green.cast[DType.int32]() * 19235 + red.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c, y.cast[DType.uint8]())
                        c += 8
                for cc in range(c, npx):
                    var i = base + cc * 3
                    var x0 = Int(qa[unsafe_offset=i])
                    var x1 = Int(qa[unsafe_offset=i + 1])
                    var x2 = Int(qa[unsafe_offset=i + 2])
                    var b = x0 if code == 0 else x2
                    var rr = x2 if code == 0 else x0
                    qo[unsafe_offset=r * npx + cc] = UInt8((b * 3735 + x1 * 19235 + rr * 9798 + 16384) >> 15)
                return
        comptime if dt == DType.uint8:
            if code == 6:
                var base = r * npx * 3
                var qa = pa.unsafe_bitcast[UInt8]()
                var qo = po.unsafe_bitcast[UInt8]()
                var c = 0
                while c + 16 <= npx:
                    var v0 = (qa + base + c * 3).unsafe_load[width=32]()
                    var v1 = (qa + base + c * 3 + 32).unsafe_load[width=16]()
                    var b16 = SIMD[DType.uint8, 16](v0[0], v0[3], v0[6], v0[9], v0[12], v0[15], v0[18], v0[21], v0[24], v0[27], v0[30], v1[1], v1[4], v1[7], v1[10], v1[13]).cast[DType.int32]()
                    var g16 = SIMD[DType.uint8, 16](v0[1], v0[4], v0[7], v0[10], v0[13], v0[16], v0[19], v0[22], v0[25], v0[28], v0[31], v1[2], v1[5], v1[8], v1[11], v1[14]).cast[DType.int32]()
                    var r16 = SIMD[DType.uint8, 16](v0[2], v0[5], v0[8], v0[11], v0[14], v0[17], v0[20], v0[23], v0[26], v0[29], v1[0], v1[3], v1[6], v1[9], v1[12], v1[15]).cast[DType.int32]()
                    var y16 = (b16 * 3735 + g16 * 19235 + r16 * 9798 + 16384) >> 15
                    var dl = SIMD[DType.int32, 16]((128 << 14) + (1 << 13))
                    var cb16 = ((b16 - y16) * 9241 + dl) >> 14
                    var cr16 = ((r16 - y16) * 11682 + dl) >> 14
                    var yi = y16.clamp(0, 255).cast[DType.uint8]()
                    var cbi = cb16.clamp(0, 255).cast[DType.uint8]()
                    var cri = cr16.clamp(0, 255).cast[DType.uint8]()
                    (qo + base + c * 3).unsafe_strided_store[width=16](yi, 3)
                    (qo + base + c * 3 + 1).unsafe_strided_store[width=16](cri, 3)
                    (qo + base + c * 3 + 2).unsafe_strided_store[width=16](cbi, 3)
                    c += 16
                while c + 8 <= npx:
                    var v = (qa + base + c * 3).unsafe_load[width=32]()
                    var b8 = SIMD[DType.uint8, 8](v[0], v[3], v[6], v[9], v[12], v[15], v[18], v[21]).cast[DType.int32]()
                    var g8 = SIMD[DType.uint8, 8](v[1], v[4], v[7], v[10], v[13], v[16], v[19], v[22]).cast[DType.int32]()
                    var r8 = SIMD[DType.uint8, 8](v[2], v[5], v[8], v[11], v[14], v[17], v[20], v[23]).cast[DType.int32]()
                    var y8 = (b8 * 3735 + g8 * 19235 + r8 * 9798 + 16384) >> 15
                    var dl8 = SIMD[DType.int32, 8]((128 << 14) + (1 << 13))
                    var cb8 = ((b8 - y8) * 9241 + dl8) >> 14
                    var cr8 = ((r8 - y8) * 11682 + dl8) >> 14
                    var yi8 = y8.clamp(0, 255).cast[DType.uint8]()
                    var cbi8 = cb8.clamp(0, 255).cast[DType.uint8]()
                    var cri8 = cr8.clamp(0, 255).cast[DType.uint8]()
                    (qo + base + c * 3).unsafe_strided_store[width=8](yi8, 3)
                    (qo + base + c * 3 + 1).unsafe_strided_store[width=8](cri8, 3)
                    (qo + base + c * 3 + 2).unsafe_strided_store[width=8](cbi8, 3)
                    c += 8
                for cc in range(c, npx):
                    var i = base + cc * 3
                    var x0 = Int(qa[unsafe_offset=i])
                    var x1 = Int(qa[unsafe_offset=i + 1])
                    var x2 = Int(qa[unsafe_offset=i + 2])
                    var y = (x0 * 3735 + x1 * 19235 + x2 * 9798 + 16384) >> 15
                    var dl = (128 << 14) + (1 << 13)
                    qo[unsafe_offset=i] = UInt8(y)
                    qo[unsafe_offset=i + 1] = UInt8(max(0, min(255, ((x2 - y) * 11682 + dl) >> 14)))
                    qo[unsafe_offset=i + 2] = UInt8(max(0, min(255, ((x0 - y) * 9241 + dl) >> 14)))
                return
        var c0 = 0
        comptime if dt == DType.uint8:

            # 16 pixels at a time for the channel-shuffle and gray conversions
            if code == 0 or code == 1 or code == 3:
                var qa = pa.unsafe_bitcast[UInt8]()
                var qo = po.unsafe_bitcast[UInt8]()
                while c0 + 16 <= npx:
                    var i = (r * npx + c0) * 3
                    var b = (qa + i).unsafe_strided_load[width=16](3)
                    var g = (qa + i + 1).unsafe_strided_load[width=16](3)
                    var rr = (qa + i + 2).unsafe_strided_load[width=16](3)
                    if code == 3:
                        (qo + i).unsafe_strided_store[width=16](rr, 3)
                        (qo + i + 1).unsafe_strided_store[width=16](g, 3)
                        (qo + i + 2).unsafe_strided_store[width=16](b, 3)
                    else:
                        var bb = b if code == 0 else rr
                        var r2 = rr if code == 0 else b
                        var y = (bb.cast[DType.int32]() * 3735 + g.cast[DType.int32]() * 19235 + r2.cast[DType.int32]() * 9798 + 16384) >> 15
                        qo.unsafe_store(r * npx + c0, y.cast[DType.uint8]())
                    c0 += 16
        for c in range(c0, npx):
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

    par(row, src.rows)
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

    par(hrow, src.rows)

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

    par(vrow, dh)
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


def sample[dt: DType](src: Mat[dt], ps: Ptr[Scalar[dt]], fx: Float64, fy: Float64, kind: Int, mode: Int, bval: Scalar[dt], dst: Ptr[Scalar[dt]]):
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
    var ch = src.ch
    var inside = sx - off >= 0 and sy - off >= 0 and sx - off + n <= src.cols and sy - off + n <= src.rows
    if inside and kind == 1:
        var w00 = wy[0] * wx[0]
        var w01 = wy[0] * wx[1]
        var w10 = wy[1] * wx[0]
        var w11 = wy[1] * wx[1]
        var r0 = (sy * src.cols + sx) * ch
        var r1 = r0 + src.cols * ch
        for k in range(ch):
            var v = w00 * Float64(ps[unsafe_offset=r0 + k]) + w01 * Float64(ps[unsafe_offset=r0 + ch + k]) + w10 * Float64(ps[unsafe_offset=r1 + k]) + w11 * Float64(ps[unsafe_offset=r1 + ch + k])
            comptime if dt.is_integral():
                v = max(Float64(Scalar[dt].MIN), min(Float64(Scalar[dt].MAX), v.__round__()))
            dst[unsafe_offset=k] = Scalar[dt](v)
        return
    for k in range(ch):
        var acc = Float64(0)
        if inside:
            for a in range(n):
                var row = ((sy + a - off) * src.cols + sx - off) * ch + k
                for b in range(n):
                    acc += wy[a] * wx[b] * Float64(ps[unsafe_offset=row + b * ch])
        else:
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
    var ps = src.ptr()
    var bv = Scalar[dt](bval)

    def row(y: Int) {imm}:
        for x in range(dw):
            var fx = pm[unsafe_offset=0] * Float64(x) + pm[unsafe_offset=1] * Float64(y) + pm[unsafe_offset=2]
            var fy = pm[unsafe_offset=3] * Float64(x) + pm[unsafe_offset=4] * Float64(y) + pm[unsafe_offset=5]
            sample(src, ps, fx, fy, kind, mode, bv, po + (y * dw + x) * src.ch)

    par(row, dh)
    _ = len(m)
    return o^


def remap[dt: DType](src: Mat[dt], mx: Mat[F32], my: Mat[F32], kind: Int, mode: Int, bval: Float64) -> Mat[dt]:
    var o = Mat[dt](mx.rows, mx.cols, src.ch)
    var po = o.ptr()
    var ps = src.ptr()
    var bv = Scalar[dt](bval)
    var pmx = mx.ptr()
    var pmy = my.ptr()

    def row(y: Int) {imm}:
        for x in range(mx.cols):
            var i = y * mx.cols + x
            sample(src, ps, Float64(pmx[unsafe_offset=i]), Float64(pmy[unsafe_offset=i]), kind, mode, bv, po + i * src.ch)

    par(row, mx.rows)
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


# ---- connected components ---------------------------------------------------------------------------------


def find_root(parent: Ptr[Int32], i: Int32) -> Int32:
    var r = i
    while parent[unsafe_offset=Int(r)] != r:
        r = parent[unsafe_offset=Int(r)]
    return r


def components(src: Mat[DType.uint8], conn: Int) -> Tuple[Mat[DType.int32], Mat[DType.int32], Mat[DType.float64]]:
    """connectedComponentsWithStats: labels in raster order of each component's first pixel, label 0 is the background;
    stats rows are left, top, width, height, area; centroids are float64 (x, y)."""
    var rows = src.rows
    var cols = src.cols
    var lab = Mat[DType.int32](rows, cols, 1)
    var parent = List[Int32](length=rows * cols // 2 + 2, fill=0)
    var pp = ptr_of(parent)
    var pl = lab.ptr()
    var ps = src.ptr()
    var count: Int32 = 0
    for y in range(rows):
        for x in range(cols):
            if ps[unsafe_offset=y * cols + x] == 0:
                continue
            var best: Int32 = 0
            comptime for k in range(4):
                var nx = x + (-1 if k == 0 else (-1 if k == 1 else (0 if k == 2 else 1)))
                var ny = y - (0 if k == 0 else 1)
                if (k == 0 or conn == 8 or k == 2) and nx >= 0 and nx < cols and ny >= 0:
                    var l = pl[unsafe_offset=ny * cols + nx]
                    if l != 0:
                        if best == 0:
                            best = find_root(pp, l)
                        else:
                            var r = find_root(pp, l)
                            if r != best:
                                if r < best:
                                    pp[unsafe_offset=Int(best)] = r
                                    best = r
                                else:
                                    pp[unsafe_offset=Int(r)] = best
            if best == 0:
                count += 1
                pp[unsafe_offset=Int(count)] = count
                best = count
            pl[unsafe_offset=y * cols + x] = best
    var remap_ = List[Int32](length=Int(count) + 1, fill=0)
    var n: Int32 = 0
    for i in range(1, Int(count) + 1):
        if pp[unsafe_offset=i] == Int32(i):
            n += 1
            remap_[i] = n
        else:
            remap_[i] = remap_[Int(find_root(pp, Int32(i)))]
    var nl = Int(n) + 1
    var stats = Mat[DType.int32](nl, 5, 1)
    var cen = Mat[DType.float64](nl, 2, 1)
    var sx = List[Float64](length=nl, fill=0)
    var sy = List[Float64](length=nl, fill=0)
    for i in range(nl):
        stats.set(i, 0, 0, Int32(cols))
        stats.set(i, 1, 0, Int32(rows))
        stats.set(i, 2, 0, -1)
        stats.set(i, 3, 0, -1)
    for y in range(rows):
        for x in range(cols):
            var l = 0
            if pl[unsafe_offset=y * cols + x] != 0:
                l = Int(remap_[Int(pl[unsafe_offset=y * cols + x])])
                pl[unsafe_offset=y * cols + x] = Int32(l)
            stats.set(l, 0, 0, min(stats.at(l, 0), Int32(x)))
            stats.set(l, 1, 0, min(stats.at(l, 1), Int32(y)))
            stats.set(l, 2, 0, max(stats.at(l, 2), Int32(x)))
            stats.set(l, 3, 0, max(stats.at(l, 3), Int32(y)))
            stats.set(l, 4, 0, stats.at(l, 4) + 1)
            sx[l] += Float64(x)
            sy[l] += Float64(y)
    for l in range(nl):
        var area = Float64(stats.at(l, 4))
        stats.set(l, 2, 0, stats.at(l, 2) - stats.at(l, 0) + 1)
        stats.set(l, 3, 0, stats.at(l, 3) - stats.at(l, 1) + 1)
        cen.set(l, 0, 0, sx[l] / area)
        cen.set(l, 1, 0, sy[l] / area)
    return (lab^, stats^, cen^)


# ---- Canny ------------------------------------------------------------------------------------------------


def canny(src: Mat[DType.uint8], t1: Float64, t2: Float64, aperture: Int, l2: Bool) -> Mat[DType.uint8]:
    """cv2.Canny: Sobel (replicate border), non-maximum suppression with cv2's fixed-point tangent tests
    (tan 22.5 deg = 13573 / 2^15), hysteresis by 8-connected flood from the strong pixels."""
    var dx = sobel[DType.uint8, DType.int16](src, 1, 0, aperture, 1.0, 1)
    var dy = sobel[DType.uint8, DType.int16](src, 0, 1, aperture, 1.0, 1)
    var rows = src.rows
    var cols = src.cols
    var lo = min(t1, t2)
    var hi = max(t1, t2)
    if l2:
        lo = min(32767.0, lo)
        hi = min(32767.0, hi)
        lo = lo * lo if lo > 0 else lo
        hi = hi * hi if hi > 0 else hi
    var low = Int(floor(lo))
    var high = Int(floor(hi))
    var mag = List[Int32](length=rows * cols, fill=0)
    var pmag = ptr_of(mag)
    var pdx = dx.ptr()
    var pdy = dy.ptr()

    def mrow(y: Int) {imm}:
        for x in range(cols):
            var a = Int32(pdx[unsafe_offset=y * cols + x])
            var b = Int32(pdy[unsafe_offset=y * cols + x])
            pmag[unsafe_offset=y * cols + x] = (a * a + b * b) if l2 else (abs(a) + abs(b))

    par(mrow, rows)
    var map = Mat[DType.uint8](rows, cols, 1)  # 1 not an edge, 0 weak candidate, 3 strong
    var pm = map.ptr()

    def nrow(y: Int) {imm}:
        for x in range(cols):
            var i = y * cols + x
            var m = Int(pmag[unsafe_offset=i])
            var xs = Int(pdx[unsafe_offset=i])
            var ys = Int(pdy[unsafe_offset=i])
            var ok = False
            if m > low:
                var ax = abs(xs)
                var ay = abs(ys) << 15
                var tg22x = ax * 13573
                var e = Int(pmag[unsafe_offset=i - 1]) if x > 0 else 0
                var w = Int(pmag[unsafe_offset=i + 1]) if x + 1 < cols else 0
                if ay < tg22x:
                    ok = m > e and m >= w
                else:
                    var tg67x = tg22x + (ax << 16)
                    var up = Int(pmag[unsafe_offset=i - cols]) if y > 0 else 0
                    var dn = Int(pmag[unsafe_offset=i + cols]) if y + 1 < rows else 0
                    if ay > tg67x:
                        ok = m > up and m >= dn
                    else:
                        var sg = -1 if (xs ^ ys) < 0 else 1
                        var xa = x - sg
                        var xb = x + sg
                        var pa = Int(pmag[unsafe_offset=i - cols - sg]) if (y > 0 and xa >= 0 and xa < cols) else 0
                        var pb = Int(pmag[unsafe_offset=i + cols + sg]) if (y + 1 < rows and xb >= 0 and xb < cols) else 0
                        ok = m > pa and m > pb
            pm[unsafe_offset=i] = UInt8((3 if m > high else 0) if ok else 1)

    par(nrow, rows)
    var stack = List[Int](capacity=1024)
    for i in range(rows * cols):
        if pm[unsafe_offset=i] == 3:
            pm[unsafe_offset=i] = 2
            stack.append(i)
    while len(stack) > 0:
        var i = stack.pop()
        var y = i // cols
        var x = i % cols
        for ddy in range(-1, 2):
            for ddx in range(-1, 2):
                var ny = y + ddy
                var nx = x + ddx
                if ny >= 0 and ny < rows and nx >= 0 and nx < cols:
                    var j = ny * cols + nx
                    if pm[unsafe_offset=j] == 0 or pm[unsafe_offset=j] == 3:
                        pm[unsafe_offset=j] = 2
                        stack.append(j)
    var o = Mat[DType.uint8](rows, cols, 1)
    for i in range(rows * cols):
        o.data[i] = 255 if pm[unsafe_offset=i] == 2 else 0
    _ = (dx.rows, dy.rows, len(mag), map.rows)
    return o^


# ---- findContours -----------------------------------------------------------------------------------------


def find_contours(src: Mat[DType.uint8], external: Bool, simple: Bool) -> Tuple[Mat[DType.int32], Mat[DType.int32]]:
    """Suzuki and Abe border following as cv2 does it: raster scan, outer and hole borders, points emitted in
    follow order starting at the first pixel found. Returns (points (n, 2) int32, lengths (k, 1) int32)."""
    var w = src.cols + 2
    var h = src.rows + 2
    var img = List[Int32](length=w * h, fill=0)
    var pi = ptr_of(img)
    for y in range(src.rows):
        for x in range(src.cols):
            if src.data[y * src.cols + x] != 0:
                pi[unsafe_offset=(y + 1) * w + x + 1] = 1
    var dxs = SIMD[DType.int32, 8](1, 1, 0, -1, -1, -1, 0, 1)
    var dys = SIMD[DType.int32, 8](0, -1, -1, -1, 0, 1, 1, 1)
    var pts = List[Int32]()
    var lens = List[Int32]()
    var ctype: List[Int] = [1, 1]  # by border id (nbd): 1 outer, 0 hole; id 1 is the frame
    var cpar: List[Int] = [0, 1]
    var nbd = 1
    for y in range(1, h - 1):
        var lnbd = 1
        for x in range(1, w - 1):
            var f = Int(pi[unsafe_offset=y * w + x])
            var is_outer = f == 1 and pi[unsafe_offset=y * w + x - 1] == 0
            var is_hole = f >= 1 and pi[unsafe_offset=y * w + x + 1] == 0
            if is_outer or is_hole:
                if not is_outer and f > 1:
                    lnbd = f
                var outer = is_outer
                nbd += 1
                var tb = ctype[lnbd]
                var parent = (cpar[lnbd] if tb == 1 else lnbd) if outer else (lnbd if tb == 1 else cpar[lnbd])
                ctype.append(1 if outer else 0)
                cpar.append(parent)
                var keep = (not external) or (outer and parent == 1)
                var start = len(pts)
                var cx = x
                var cy = y
                var s = 4 if outer else 0
                var s_end = s
                var found = False
                while True:
                    s = (s - 1) & 7
                    if pi[unsafe_offset=(cy + Int(dys[s])) * w + cx + Int(dxs[s])] != 0:
                        found = True
                        break
                    if s == s_end:
                        break
                if not found:
                    pi[unsafe_offset=y * w + x] = Int32(-nbd)
                    if keep:
                        pts.append(Int32(x - 1))
                        pts.append(Int32(y - 1))
                else:
                    var i3x = cx
                    var i3y = cy
                    var prev_s = s ^ 4
                    var i1x = cx + Int(dxs[s])
                    var i1y = cy + Int(dys[s])
                    while True:
                        s_end = s
                        var i4x = 0
                        var i4y = 0
                        while True:
                            s += 1
                            i4x = i3x + Int(dxs[s & 7])
                            i4y = i3y + Int(dys[s & 7])
                            if pi[unsafe_offset=i4y * w + i4x] != 0:
                                break
                        s &= 7
                        if UInt(s - 1) < UInt(s_end):
                            pi[unsafe_offset=i3y * w + i3x] = Int32(-nbd)
                        elif pi[unsafe_offset=i3y * w + i3x] == 1:
                            pi[unsafe_offset=i3y * w + i3x] = Int32(nbd)
                        if keep and (s != prev_s or not simple):
                            pts.append(Int32(i3x - 1))
                            pts.append(Int32(i3y - 1))
                            prev_s = s
                        if i4x == cx and i4y == cy and i3x == i1x and i3y == i1y:
                            break
                        i3x = i4x
                        i3y = i4y
                        s = (s + 4) & 7
                if keep:
                    lens.append(Int32((len(pts) - start) // 2))
            f = Int(pi[unsafe_offset=y * w + x])
            if f != 1 and f != 0:
                lnbd = abs(f)
    # cv2 returns the contours last found first
    var op = Mat[DType.int32](len(pts) // 2, 2, 1)
    var ol = Mat[DType.int32](len(lens), 1, 1)
    var src_at = len(pts)
    var dst_at = 0
    for c in range(len(lens)):
        var k = 2 * Int(lens[len(lens) - 1 - c])
        src_at -= k
        for i in range(k):
            op.data[dst_at + i] = pts[src_at + i]
        dst_at += k
        ol.data[c] = lens[len(lens) - 1 - c]
    return (op^, ol^)


# ---- goodFeaturesToTrack ----------------------------------------------------------------------------------


def good_features(src: Mat[DType.uint8], max_corners: Int, quality: Float64, min_dist: Float64, block: Int) -> Mat[F32]:
    """Shi-Tomasi: smallest eigenvalue of the windowed gradient covariance, local maxima above quality * max,
    strongest first (ties by position), thinned by a minimum distance on a grid. Returns (n, 2) float32 (x, y)."""
    var scale = Float32(1.0 / (4.0 * Float64(block) * 255.0))
    var dx = sobel[DType.uint8, F32](src, 1, 0, 3, scale)
    var dy = sobel[DType.uint8, F32](src, 0, 1, 3, scale)
    var n = src.rows * src.cols
    var cov = Mat[F32](src.rows, src.cols, 3)
    for i in range(n):
        cov.data[3 * i] = dx.data[i] * dx.data[i]
        cov.data[3 * i + 1] = dx.data[i] * dy.data[i]
        cov.data[3 * i + 2] = dy.data[i] * dy.data[i]
    var box = List[Float32](length=block, fill=1)
    var sums = sepfilter[F32, F32](cov, box, box)
    var eig = Mat[F32](src.rows, src.cols, 1)
    var best = Float32(0)
    for i in range(n):
        var a = sums.data[3 * i] * 0.5
        var b = sums.data[3 * i + 1]
        var c = sums.data[3 * i + 2] * 0.5
        eig.data[i] = (a + c) - sqrt((a - c) * (a - c) + b * b)
        best = max(best, eig.data[i])
    var thr = Float32(Float64(best) * quality)
    var kept = Mat[F32](src.rows, src.cols, 1)
    for i in range(n):
        kept.data[i] = eig.data[i] if eig.data[i] > thr else 0
    var dil = morph[False, F32](kept, 0, 3, 1)
    var cand = List[Int]()
    for i in range(n):
        if kept.data[i] != 0 and kept.data[i] == dil.data[i]:
            cand.append(i)

    def stronger(p: Int, q: Int) {imm} -> Bool:
        return eig.data[p] > eig.data[q] or (eig.data[p] == eig.data[q] and p < q)

    sort(Span(cand), stronger)
    var cell = max(rint(min_dist), 1)
    var gw = (src.cols + cell - 1) // cell
    var gh = (src.rows + cell - 1) // cell
    var grid = List[List[Int]](length=gw * gh, fill=List[Int]())
    var chosen = List[Int]()
    var md2 = min_dist * min_dist
    for c in cand:
        var y = c // src.cols
        var x = c % src.cols
        var good = True
        if min_dist >= 1:
            var xc = x // cell
            var yc = y // cell
            for yy in range(max(yc - 1, 0), min(yc + 2, gh)):
                for xx in range(max(xc - 1, 0), min(xc + 2, gw)):
                    for m in grid[yy * gw + xx]:
                        var ddx = Float64(x - m % src.cols)
                        var ddy = Float64(y - m // src.cols)
                        if ddx * ddx + ddy * ddy < md2:
                            good = False
            if good:
                grid[yc * gw + xc].append(c)
        if good:
            chosen.append(c)
            if max_corners > 0 and len(chosen) == max_corners:
                break
    var o = Mat[F32](len(chosen), 2, 1)
    for i in range(len(chosen)):
        o.data[2 * i] = Float32(chosen[i] % src.cols)
        o.data[2 * i + 1] = Float32(chosen[i] // src.cols)
    return o^


# ---- drawing ----------------------------------------------------------------------------------------------


def clip_line(cols: Int, rows: Int, mut x1: Int, mut y1: Int, mut x2: Int, mut y2: Int) -> Bool:
    """cv2.clipLine, including its integer truncation, so clipped lines rasterize identically."""
    var right = cols - 1
    var bottom = rows - 1
    var c1 = Int(x1 < 0) + Int(x1 > right) * 2 + Int(y1 < 0) * 4 + Int(y1 > bottom) * 8
    var c2 = Int(x2 < 0) + Int(x2 > right) * 2 + Int(y2 < 0) * 4 + Int(y2 > bottom) * 8
    if (c1 & c2) == 0 and (c1 | c2) != 0:
        if (c1 & 12) != 0:
            var a = 0 if c1 < 8 else bottom
            x1 += Int(Float64(a - y1) * Float64(x2 - x1) / Float64(y2 - y1))
            y1 = a
            c1 = Int(x1 < 0) + Int(x1 > right) * 2
        if (c2 & 12) != 0:
            var a = 0 if c2 < 8 else bottom
            x2 += Int(Float64(a - y2) * Float64(x2 - x1) / Float64(y2 - y1))
            y2 = a
            c2 = Int(x2 < 0) + Int(x2 > right) * 2
        if (c1 & c2) == 0 and (c1 | c2) != 0:
            if c1 != 0:
                var a = 0 if c1 == 1 else right
                y1 += Int(Float64(a - x1) * Float64(y2 - y1) / Float64(x2 - x1))
                x1 = a
                c1 = 0
            if c2 != 0:
                var a = 0 if c2 == 1 else right
                y2 += Int(Float64(a - x2) * Float64(y2 - y1) / Float64(x2 - x1))
                x2 = a
                c2 = 0
    return (c1 | c2) == 0


def draw_line[dt: DType](mut m: Mat[dt], px1: Int, py1: Int, px2: Int, py2: Int, color: List[Float64]):
    """cv2.line, thickness 1, LINE_8: clip, then the error-term walk of cv2's LineIterator (left to right)."""
    var x1 = px1
    var y1 = py1
    var x2 = px2
    var y2 = py2
    if not clip_line(m.cols, m.rows, x1, y1, x2, y2):
        return
    if x2 < x1:
        swap(x1, x2)
        swap(y1, y2)
    var dx = x2 - x1
    var dy = abs(y2 - y1)
    var ystep = 1 if y2 >= y1 else -1
    var steep = dy > dx
    var major = dy if steep else dx
    var minor = dx if steep else dy
    var err = major - 2 * minor
    var x = x1
    var y = y1
    for _ in range(major + 1):
        for k in range(m.ch):
            m.set(y, x, k, Scalar[dt](color[k] if k < len(color) else 0.0))
        if steep:
            y += ystep
        else:
            x += 1
        if err < 0:
            if steep:
                x += 1
            else:
                y += ystep
            err += 2 * major - 2 * minor
        else:
            err -= 2 * minor


def draw_rect[dt: DType](mut m: Mat[dt], x1: Int, y1: Int, x2: Int, y2: Int, color: List[Float64], thick: Int):
    """cv2.rectangle: thickness 1 draws the four edges, a negative thickness fills the clipped box."""
    if thick < 0:
        for y in range(max(min(y1, y2), 0), min(max(y1, y2), m.rows - 1) + 1):
            for x in range(max(min(x1, x2), 0), min(max(x1, x2), m.cols - 1) + 1):
                for k in range(m.ch):
                    m.set(y, x, k, Scalar[dt](color[k] if k < len(color) else 0.0))
        return
    draw_line(m, x1, y1, x2, y1, color)
    draw_line(m, x2, y1, x2, y2, color)
    draw_line(m, x2, y2, x1, y2, color)
    draw_line(m, x1, y2, x1, y1, color)


# ---- HOG people detector ----------------------------------------------------------------------------------
# Dalal and Triggs 2005 with the OpenCV defaults: 64 x 128 window, 16 x 16 blocks every 8 pixels, 8 x 8 cells, 9
# unsigned orientation bins, square-root gamma, [-1 0 1] gradients (reflect101), Gaussian block window of sigma 4 ((block w + block h) / 8),
# trilinear voting, L2-Hys block normalisation. The linear SVM (3780 weights + bias) is an input file.


def hog_blocks(src: Mat[DType.uint8]) -> Mat[F32]:
    """Normalised 36-vectors for every 16 x 16 block on the 8-pixel grid: (block rows, block cols, 36); cells inside
    a block are ordered column-major (x outer) like cv2, bins fastest."""
    var h = src.rows
    var w = src.cols
    var nby = (h - 16) // 8 + 1
    var nbx = (w - 16) // 8 + 1
    var o = Mat[F32](max(nby, 0), max(nbx, 0), 36)
    if nby <= 0 or nbx <= 0:
        return o^
    var lut = List[Float32](length=256, fill=0)
    for i in range(256):
        lut[i] = sqrt(Float32(i))
    var bin0 = Mat[DType.int32](h, w, 1)
    var wt0 = Mat[F32](h, w, 1)
    var wt1 = Mat[F32](h, w, 1)
    var pb = bin0.ptr()
    var p0 = wt0.ptr()
    var p1 = wt1.ptr()
    var pl = ptr_of(lut)

    def grad(y: Int) {imm}:
        for x in range(w):
            var xa = bidx(x - 1, w, 0)
            var xb = bidx(x + 1, w, 0)
            var ya = bidx(y - 1, h, 0)
            var yb = bidx(y + 1, h, 0)
            var gx = pl[unsafe_offset=Int(src.at(y, xb))] - pl[unsafe_offset=Int(src.at(y, xa))]
            var gy = pl[unsafe_offset=Int(src.at(yb, x))] - pl[unsafe_offset=Int(src.at(ya, x))]
            var mag = sqrt(gx * gx + gy * gy)
            var ang = atan2(Float64(gy), Float64(gx))
            if ang < 0:
                ang += 3.14159265358979323846
            var fb = ang * 9.0 / 3.14159265358979323846 - 0.5
            var b0 = Int(floor(fb))
            var wb = Float32(fb - Float64(b0))
            pb[unsafe_offset=y * w + x] = Int32(b0)
            p0[unsafe_offset=y * w + x] = mag * (1 - wb)
            p1[unsafe_offset=y * w + x] = mag * wb

    par(grad, h, 16)
    var po = o.ptr()

    # per block pixel: Gaussian window times trilinear weight for each of the four neighbouring cells
    var wtab = List[Float32](length=256 * 4, fill=0)
    for i in range(16):
        var fy = (Float32(i) + 0.5) / 8.0 - 0.5
        var cy0 = Int(floor(fy))
        var wy = fy - Float32(cy0)
        for j in range(16):
            var fx = (Float32(j) + 0.5) / 8.0 - 0.5
            var cx0 = Int(floor(fx))
            var wx = fx - Float32(cx0)
            var di = Float32(i - 8)
            var dj = Float32(j - 8)
            var g = Float32(exp(Float64(-(di * di + dj * dj) / 32.0)))
            for cyi in range(2):
                for cxi in range(2):
                    var cy = cy0 + cyi
                    var cx = cx0 + cxi
                    if cx >= 0 and cx < 2 and cy >= 0 and cy < 2:
                        var w1 = wy if cyi == 1 else 1 - wy
                        var w2 = wx if cxi == 1 else 1 - wx
                        wtab[(i * 16 + j) * 4 + cx * 2 + cy] = g * w1 * w2
    var pw = ptr_of(wtab)

    def block(t: Int) {imm}:
        var by = (t // nbx) * 8
        var bx = (t % nbx) * 8
        var hist = SIMD[F32, 64](0)
        for i in range(16):
            for j in range(16):
                var idx = (by + i) * w + bx + j
                var b0 = Int(pb[unsafe_offset=idx])
                var b1 = (b0 + 1) % 9
                b0 = ((b0 % 9) + 9) % 9
                var v0 = p0[unsafe_offset=idx]
                var v1 = p1[unsafe_offset=idx]
                comptime for cell in range(4):
                    var wc = pw[unsafe_offset=(i * 16 + j) * 4 + cell]
                    hist[cell * 9 + b0] += v0 * wc
                    hist[cell * 9 + b1] += v1 * wc
        var sum = Float32(0)
        for k in range(36):
            sum += hist[k] * hist[k]
        var sc = 1.0 / (sqrt(sum) + 3.6)
        var sum2 = Float32(0)
        for k in range(36):
            hist[k] = min(hist[k] * sc, 0.2)
            sum2 += hist[k] * hist[k]
        var sc2 = 1.0 / (sqrt(sum2) + 1e-3)
        for k in range(36):
            po[unsafe_offset=t * 36 + k] = hist[k] * sc2

    par(block, nby * nbx, 16)
    _ = (bin0.rows, wt0.rows, wt1.rows, len(lut), len(wtab))
    return o^


def hog_scores(blocks: Mat[F32], svm: Mat[F32]) -> Mat[F32]:
    """SVM score of every 64 x 128 window on the 8-pixel grid: (window rows, window cols)."""
    var ny = blocks.rows - 14
    var nx = blocks.cols - 6
    var o = Mat[F32](max(ny, 0), max(nx, 0), 1)
    if ny <= 0 or nx <= 0:
        return o^
    var po = o.ptr()
    var pbk = blocks.ptr()
    var ps = svm.ptr()
    var nbx = blocks.cols

    def row(wy: Int) {imm}:
        for wx in range(nx):
            var acc = ps[unsafe_offset=3780]
            for i in range(7):
                for j in range(15):
                    var bo = ((wy + j) * nbx + wx + i) * 36
                    var so = (i * 15 + j) * 36
                    for t in range(36):
                        acc += ps[unsafe_offset=so + t] * pbk[unsafe_offset=bo + t]
            po[unsafe_offset=wy * nx + wx] = acc

    par(row, ny, 16)
    return o^


def group_rects(r: List[Int], thresh: Int) -> List[Int]:
    """cv2.groupRectangles(eps = 0.2): cluster similar boxes, average each cluster, drop clusters of at most
    `thresh` boxes and small boxes sitting inside a larger supported one. r holds x, y, w, h per box."""
    var n = len(r) // 4
    var out = List[Int]()
    if thresh <= 0 or n == 0:
        for v in r:
            out.append(v)
        return out^
    var parent = List[Int](length=n, fill=0)
    for i in range(n):
        parent[i] = i

    def find(mut p: List[Int], i: Int) -> Int:
        var k = i
        while p[k] != k:
            p[k] = p[p[k]]
            k = p[k]
        return k

    for i in range(n):
        for j in range(i + 1, n):
            var delta = 0.2 * Float64(min(r[4 * i + 2], r[4 * j + 2]) + min(r[4 * i + 3], r[4 * j + 3])) * 0.5
            if (Float64(abs(r[4 * i] - r[4 * j])) <= delta and Float64(abs(r[4 * i + 1] - r[4 * j + 1])) <= delta
                    and Float64(abs(r[4 * i] + r[4 * i + 2] - r[4 * j] - r[4 * j + 2])) <= delta
                    and Float64(abs(r[4 * i + 1] + r[4 * i + 3] - r[4 * j + 1] - r[4 * j + 3])) <= delta):
                var a = find(parent, i)
                var b = find(parent, j)
                if a != b:
                    parent[b] = a
    var cls = List[Int](length=n, fill=-1)
    var nc = 0
    var sums = List[Int]()
    var cnt = List[Int]()
    for i in range(n):
        var root = find(parent, i)
        if cls[root] < 0:
            cls[root] = nc
            nc += 1
            for _ in range(4):
                sums.append(0)
            cnt.append(0)
        var c = cls[root]
        for k in range(4):
            sums[4 * c + k] += r[4 * i + k]
        cnt[c] += 1
    var avg = List[Int](length=4 * nc, fill=0)
    for c in range(nc):
        for k in range(4):
            avg[4 * c + k] = rint(Float64(Float32(sums[4 * c + k]) * (1.0 / Float32(cnt[c]))))
    for i in range(nc):
        if cnt[i] <= thresh:
            continue
        var inside = False
        for j in range(nc):
            if j == i or cnt[j] <= thresh:
                continue
            var dx = Int(Float64(avg[4 * j + 2]) * 0.2 + 0.5)
            var dy = Int(Float64(avg[4 * j + 3]) * 0.2 + 0.5)
            if (avg[4 * i] >= avg[4 * j] - dx and avg[4 * i + 1] >= avg[4 * j + 1] - dy
                    and avg[4 * i] + avg[4 * i + 2] <= avg[4 * j] + avg[4 * j + 2] + dx
                    and avg[4 * i + 1] + avg[4 * i + 3] <= avg[4 * j + 1] + avg[4 * j + 3] + dy
                    and (cnt[j] > max(3, cnt[i]) or cnt[i] < 3)):
                inside = True
        if not inside:
            for k in range(4):
                out.append(avg[4 * i + k])
    return out^


def hog_detect(src: Mat[DType.uint8], svm: Mat[F32], hit: Float32, scale0: Float64, group: Int) -> Mat[DType.int32]:
    """HOGDescriptor.detectMultiScale with winStride 8 and no padding: (n, 4) boxes x, y, w, h."""
    var scales = List[Float64]()
    var sc = Float64(1)
    for _ in range(64):
        scales.append(sc)
        if rint(Float64(src.cols) / sc) < 64 or rint(Float64(src.rows) / sc) < 128 or scale0 <= 1.0:
            break
        sc *= scale0
    var found = List[Int]()
    for s in scales:
        var w = rint(Float64(src.cols) / s)
        var h = rint(Float64(src.rows) / s)
        if w < 64 or h < 128:
            continue
        var lvl = Mat[DType.uint8](copy=src) if (w == src.cols and h == src.rows) else resize(src, w, h, 1)
        var sc_ = hog_scores(hog_blocks(lvl), svm)
        for wy in range(sc_.rows):
            for wx in range(sc_.cols):
                if sc_.at(wy, wx) >= hit:
                    found.append(rint(Float64(wx * 8) * s))
                    found.append(rint(Float64(wy * 8) * s))
                    found.append(rint(64.0 * s))
                    found.append(rint(128.0 * s))
    var g = group_rects(found, group)
    var o = Mat[DType.int32](len(g) // 4, 4, 1)
    for i in range(len(g)):
        o.data[i] = Int32(g[i])
    return o^


# ---- GrabCut ----------------------------------------------------------------------------------------------
# Rother, Kolmogorov, Blake 2004: iterate (assign GMM components, refit two 5-component colour GMMs, min-cut on a
# 8-neighbour contrast graph). The cut is Dinic's algorithm; cv2 uses Boykov-Kolmogorov and a different k-means seed,
# so masks agree up to ties and cluster seeding, not bit for bit.

comptime GC_BGD: UInt8 = 0
comptime GC_FGD: UInt8 = 1
comptime GC_PR_BGD: UInt8 = 2
comptime GC_PR_FGD: UInt8 = 3


struct Gmm(Movable):
    var coef: List[Float64]
    var mean: List[Float64]
    var inv: List[Float64]
    var det: List[Float64]

    def __init__(out self):
        self.coef = List[Float64](length=5, fill=0)
        self.mean = List[Float64](length=15, fill=0)
        self.inv = List[Float64](length=45, fill=0)
        self.det = List[Float64](length=5, fill=0)

    def comp(self, k: Int, c0: Float64, c1: Float64, c2: Float64) -> Float64:
        if self.coef[k] <= 0:
            return 0.0
        var d0 = c0 - self.mean[3 * k]
        var d1 = c1 - self.mean[3 * k + 1]
        var d2 = c2 - self.mean[3 * k + 2]
        var b = 9 * k
        var m = d0 * (self.inv[b] * d0 + self.inv[b + 3] * d1 + self.inv[b + 6] * d2) + d1 * (self.inv[b + 1] * d0 + self.inv[b + 4] * d1 + self.inv[b + 7] * d2) + d2 * (self.inv[b + 2] * d0 + self.inv[b + 5] * d1 + self.inv[b + 8] * d2)
        return self.coef[k] * 1.0 / sqrt(self.det[k]) * exp(-0.5 * m)

    def prob(self, c0: Float64, c1: Float64, c2: Float64) -> Float64:
        var s = Float64(0)
        for k in range(5):
            s += self.comp(k, c0, c1, c2)
        return s

    def which(self, c0: Float64, c1: Float64, c2: Float64) -> Int:
        var best = 0
        var bp = -1.0
        for k in range(5):
            var p = self.comp(k, c0, c1, c2)
            if p > bp:
                bp = p
                best = k
        return best

    def fit(mut self, samples: List[Float64], labels: List[Int]):
        """Refit from samples (r, g, b triples) with component labels 0..4."""
        var n = len(labels)
        var cnt = List[Float64](length=5, fill=0)
        var sm = List[Float64](length=15, fill=0)
        var sp = List[Float64](length=45, fill=0)
        for i in range(n):
            var k = labels[i]
            cnt[k] += 1
            for a in range(3):
                sm[3 * k + a] += samples[3 * i + a]
                for b in range(3):
                    sp[9 * k + 3 * a + b] += samples[3 * i + a] * samples[3 * i + b]
        for k in range(5):
            if cnt[k] == 0:
                self.coef[k] = 0
                continue
            self.coef[k] = cnt[k] / Float64(n)
            var c = List[Float64](length=9, fill=0)
            for a in range(3):
                self.mean[3 * k + a] = sm[3 * k + a] / cnt[k]
            for a in range(3):
                for b in range(3):
                    c[3 * a + b] = sp[9 * k + 3 * a + b] / cnt[k] - self.mean[3 * k + a] * self.mean[3 * k + b]
            var det = c[0] * (c[4] * c[8] - c[5] * c[7]) - c[1] * (c[3] * c[8] - c[5] * c[6]) + c[2] * (c[3] * c[7] - c[4] * c[6])
            if det <= 2.220446049250313e-16:
                c[0] += 0.01
                c[4] += 0.01
                c[8] += 0.01
                det = c[0] * (c[4] * c[8] - c[5] * c[7]) - c[1] * (c[3] * c[8] - c[5] * c[6]) + c[2] * (c[3] * c[7] - c[4] * c[6])
            self.det[k] = det
            var b = 9 * k
            self.inv[b] = (c[4] * c[8] - c[5] * c[7]) / det
            self.inv[b + 3] = -(c[3] * c[8] - c[5] * c[6]) / det
            self.inv[b + 6] = (c[3] * c[7] - c[4] * c[6]) / det
            self.inv[b + 1] = -(c[1] * c[8] - c[2] * c[7]) / det
            self.inv[b + 4] = (c[0] * c[8] - c[2] * c[6]) / det
            self.inv[b + 7] = -(c[0] * c[7] - c[1] * c[6]) / det
            self.inv[b + 2] = (c[1] * c[5] - c[2] * c[4]) / det
            self.inv[b + 5] = -(c[0] * c[5] - c[2] * c[3]) / det
            self.inv[b + 8] = (c[0] * c[4] - c[1] * c[3]) / det


def kmeans5(samples: List[Float64]) -> List[Int]:
    """k-means++ seeding then ten Lloyd steps, five clusters on 3-D points."""
    var n = len(samples) // 3
    var labels = List[Int](length=n, fill=0)
    if n < 5:
        return labels^
    var state = UInt64(0x2545F4914F6CDD1D)
    var cen = List[Float64]()
    var first = Int(state % UInt64(n))
    for a in range(3):
        cen.append(samples[3 * first + a])
    var d2 = List[Float64](length=n, fill=1e300)
    for c in range(1, 5):
        var tot = Float64(0)
        for i in range(n):
            var d = Float64(0)
            for a in range(3):
                d += (samples[3 * i + a] - cen[3 * (c - 1) + a]) ** 2
            d2[i] = min(d2[i], d)
            tot += d2[i]
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        var target = Float64(state % 1000003) / 1000003.0 * tot
        var pick = 0
        var acc = Float64(0)
        for i in range(n):
            acc += d2[i]
            if acc >= target:
                pick = i
                break
        for a in range(3):
            cen.append(samples[3 * pick + a])
    for _ in range(10):
        var sums = List[Float64](length=15, fill=0)
        var cnt = List[Int](length=5, fill=0)
        for i in range(n):
            var best = 0
            var bd = 1e300
            for c in range(5):
                var d = Float64(0)
                for a in range(3):
                    d += (samples[3 * i + a] - cen[3 * c + a]) ** 2
                if d < bd:
                    bd = d
                    best = c
            labels[i] = best
            cnt[best] += 1
            for a in range(3):
                sums[3 * best + a] += samples[3 * i + a]
        for c in range(5):
            if cnt[c] > 0:
                for a in range(3):
                    cen[3 * c + a] = sums[3 * c + a] / Float64(cnt[c])
    return labels^


struct Flow(Movable):
    """Dinic max-flow on arrays; node 0 is the source, node 1 the sink."""

    var head: List[Int32]
    var nxt: List[Int32]
    var to: List[Int32]
    var cap: List[Float64]

    def __init__(out self, nodes: Int):
        self.head = List[Int32](length=nodes, fill=-1)
        self.nxt = List[Int32]()
        self.to = List[Int32]()
        self.cap = List[Float64]()

    def add(mut self, a: Int, b: Int, c_ab: Float64, c_ba: Float64):
        self.to.append(Int32(b))
        self.cap.append(c_ab)
        self.nxt.append(self.head[a])
        self.head[a] = Int32(len(self.to) - 1)
        self.to.append(Int32(a))
        self.cap.append(c_ba)
        self.nxt.append(self.head[b])
        self.head[b] = Int32(len(self.to) - 1)

    def maxflow(mut self, s: Int, t: Int) -> Float64:
        var n = len(self.head)
        var total = Float64(0)
        var level = List[Int32](length=n, fill=0)
        var it = List[Int32](length=n, fill=0)
        var queue = List[Int32](length=n, fill=0)
        while True:
            for i in range(n):
                level[i] = -1
            level[s] = 0
            var qh = 0
            var qt = 1
            queue[0] = Int32(s)
            while qh < qt:
                var u = Int(queue[qh])
                qh += 1
                var e = self.head[u]
                while e >= 0:
                    var v = Int(self.to[Int(e)])
                    if self.cap[Int(e)] > 1e-12 and level[v] < 0:
                        level[v] = level[u] + 1
                        queue[qt] = Int32(v)
                        qt += 1
                    e = self.nxt[Int(e)]
            if level[t] < 0:
                break
            for i in range(n):
                it[i] = self.head[i]
            # iterative blocking-flow DFS
            var path = List[Int32]()
            var u = s
            while True:
                if u == t:
                    var f = Float64(1e300)
                    for e in path:
                        f = min(f, self.cap[Int(e)])
                    for e in path:
                        self.cap[Int(e)] -= f
                        self.cap[Int(e) ^ 1] += f
                    total += f
                    # restart from the first saturated edge
                    var cut = 0
                    for i in range(len(path)):
                        if self.cap[Int(path[i])] <= 1e-12:
                            cut = i
                            break
                    u = s if cut == 0 else Int(self.to[Int(path[cut - 1])])
                    var np_ = List[Int32]()
                    for i in range(cut):
                        np_.append(path[i])
                    path = np_^
                    continue
                var advanced = False
                while it[u] >= 0:
                    var e = Int(it[u])
                    var v = Int(self.to[e])
                    if self.cap[e] > 1e-12 and level[v] == level[u] + 1:
                        path.append(Int32(e))
                        u = v
                        advanced = True
                        break
                    it[u] = self.nxt[e]
                if not advanced:
                    if u == s:
                        break
                    level[u] = -1
                    var last = Int(path.pop())
                    u = Int(self.to[last ^ 1])
        return total


def grab_cut(img: Mat[DType.uint8], rx: Int, ry: Int, rw: Int, rh: Int, iters: Int) -> Mat[DType.uint8]:
    """GC_INIT_WITH_RECT on a 3-channel image: returns the binary foreground mask (255 = foreground)."""
    var h = img.rows
    var w = img.cols
    var mask = Mat[DType.uint8](h, w, 1)
    for y in range(h):
        for x in range(w):
            var inside = x >= rx and x < rx + rw and y >= ry and y < ry + rh
            mask.set(y, x, 0, GC_PR_FGD if inside else GC_BGD)
    # contrast terms
    var beta = Float64(0)
    var cntn = 0
    for y in range(h):
        for x in range(w):
            for d in range(4):
                var nx = x + (-1 if d != 2 else 0) + (2 if d == 3 else 0)
                var ny = y - (0 if d == 0 else 1)
                if d == 3:
                    nx = x + 1
                if nx < 0 or nx >= w or ny < 0:
                    continue
                var dd = Float64(0)
                for c in range(3):
                    var df = Float64(img.at(y, x, c)) - Float64(img.at(ny, nx, c))
                    dd += df * df
                beta += dd
                cntn += 1
    beta = 1.0 / (2 * beta / Float64(max(cntn, 1))) if beta > 2.220446049250313e-16 else 0.0
    var gamma = 50.0
    var lam = 9 * gamma
    var nw = List[Float64](length=4 * h * w, fill=0)
    for y in range(h):
        for x in range(w):
            for d in range(4):
                var nx = x + (-1 if d != 2 else 0) + (2 if d == 3 else 0)
                var ny = y - (0 if d == 0 else 1)
                if d == 3:
                    nx = x + 1
                if nx < 0 or nx >= w or ny < 0:
                    continue
                var dd = Float64(0)
                for c in range(3):
                    var df = Float64(img.at(y, x, c)) - Float64(img.at(ny, nx, c))
                    dd += df * df
                var wgt = gamma * exp(-beta * dd)
                nw[4 * (y * w + x) + d] = wgt if (d == 0 or d == 2) else wgt / 1.4142135623730951
    var bg = Gmm()
    var fg = Gmm()
    var bs = List[Float64]()
    var fs = List[Float64]()
    for y in range(h):
        for x in range(w):
            var m = mask.at(y, x)
            var tgt = fs.copy() if False else List[Float64]()
            if m == GC_BGD or m == GC_PR_BGD:
                for c in range(3):
                    bs.append(Float64(img.at(y, x, c)))
            else:
                for c in range(3):
                    fs.append(Float64(img.at(y, x, c)))
    bg.fit(bs, kmeans5(bs))
    fg.fit(fs, kmeans5(fs))
    for _ in range(iters):
        var bl = List[Int]()
        var fl_ = List[Int]()
        var bs2 = List[Float64]()
        var fs2 = List[Float64]()
        for y in range(h):
            for x in range(w):
                var c0 = Float64(img.at(y, x, 0))
                var c1 = Float64(img.at(y, x, 1))
                var c2 = Float64(img.at(y, x, 2))
                var m = mask.at(y, x)
                if m == GC_BGD or m == GC_PR_BGD:
                    bl.append(bg.which(c0, c1, c2))
                    bs2.append(c0)
                    bs2.append(c1)
                    bs2.append(c2)
                else:
                    fl_.append(fg.which(c0, c1, c2))
                    fs2.append(c0)
                    fs2.append(c1)
                    fs2.append(c2)
        bg.fit(bs2, bl)
        fg.fit(fs2, fl_)
        var g = Flow(h * w + 2)
        for y in range(h):
            for x in range(w):
                var node = 2 + y * w + x
                var m = mask.at(y, x)
                var from_s = Float64(0)
                var to_t = Float64(0)
                if m == GC_PR_BGD or m == GC_PR_FGD:
                    var c0 = Float64(img.at(y, x, 0))
                    var c1 = Float64(img.at(y, x, 1))
                    var c2 = Float64(img.at(y, x, 2))
                    from_s = -log_(max(bg.prob(c0, c1, c2), 1e-300))
                    to_t = -log_(max(fg.prob(c0, c1, c2), 1e-300))
                elif m == GC_BGD:
                    to_t = lam
                else:
                    from_s = lam
                g.add(0, node, from_s, 0.0)
                g.add(node, 1, to_t, 0.0)
                for d in range(4):
                    var wgt = nw[4 * (y * w + x) + d]
                    if wgt > 0:
                        var nx = x + (-1 if d != 2 else 0) + (2 if d == 3 else 0)
                        var ny = y - (0 if d == 0 else 1)
                        if d == 3:
                            nx = x + 1
                        g.add(node, 2 + ny * w + nx, wgt, wgt)
        _ = g.maxflow(0, 1)
        # source side = reachable in the residual graph
        var seen = List[Bool](length=h * w + 2, fill=False)
        var stack = List[Int]()
        stack.append(0)
        seen[0] = True
        while len(stack) > 0:
            var u = stack.pop()
            var e = g.head[u]
            while e >= 0:
                var v = Int(g.to[Int(e)])
                if g.cap[Int(e)] > 1e-12 and not seen[v]:
                    seen[v] = True
                    stack.append(v)
                e = g.nxt[Int(e)]
        for y in range(h):
            for x in range(w):
                var m = mask.at(y, x)
                if m == GC_PR_BGD or m == GC_PR_FGD:
                    mask.set(y, x, 0, GC_PR_FGD if seen[2 + y * w + x] else GC_PR_BGD)
    var o = Mat[DType.uint8](h, w, 1)
    for i in range(h * w):
        o.data[i] = 255 if (mask.data[i] & 1) == 1 else 0
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


def run_u8(mut a: Args) raises -> Bool:
    var m = load[DType.uint8](a.ins[0])
    if a.op == "connectedComponentsWithStats":
        var o = (Mat[DType.int32](0, 0), Mat[DType.int32](0, 0), Mat[DType.float64](0, 0))
        while a.again():
            o = components(m, a.i("connectivity", 8))
        save(o[0], a.out)
        save(o[1], a.out + ".1")
        save(o[2], a.out + ".2")
    elif a.op == "Canny":
        var o = Mat[DType.uint8](0, 0)
        while a.again():
            o = canny(m, a.f("t1", 100.0), a.f("t2", 200.0), a.i("aperture", 3), a.i("l2", 0) == 1)
        save(o, a.out)
    elif a.op == "findContours":
        var o = (Mat[DType.int32](0, 0), Mat[DType.int32](0, 0))
        while a.again():
            o = find_contours(m, a.i("mode", 0) == 0, a.i("method", 0) == 1)
        save(o[0], a.out)
        save(o[1], a.out + ".1")
    elif a.op == "goodFeaturesToTrack":
        var o = Mat[F32](0, 0)
        while a.again():
            o = good_features(m, a.i("maxCorners", 100), a.f("quality", 0.01), a.f("minDist", 10.0), a.i("block", 3))
        save(o, a.out)
    elif a.op == "grabCut":
        var r = a.fl("rect", [0.0, 0.0, Float64(m.cols), Float64(m.rows)])
        var o = Mat[DType.uint8](0, 0)
        while a.again():
            o = grab_cut(m, Int(r[0]), Int(r[1]), Int(r[2]), Int(r[3]), a.i("iters", 5))
        save(o, a.out)
    elif a.op == "HOGScores":
        var svm = load[F32](a.ins[1])
        var o = Mat[F32](0, 0)
        while a.again():
            o = hog_scores(hog_blocks(m), svm)
        save(o, a.out)
    elif a.op == "detectMultiScale":
        var svm = load[F32](a.ins[1])
        var o = Mat[DType.int32](0, 0)
        while a.again():
            o = hog_detect(m, svm, Float32(a.f("hit", 0.0)), a.f("scale", 1.05), a.i("group", 2))
        save(o, a.out)
    elif a.op == "line" or a.op == "rectangle":
        var c = a.fl("color", [255.0, 255.0, 255.0])
        var o = Mat[DType.uint8](copy=m)
        while a.again():
            o = Mat[DType.uint8](copy=m)
            if a.op == "line":
                draw_line(o, a.i("x1", 0), a.i("y1", 0), a.i("x2", 0), a.i("y2", 0), c)
            else:
                draw_rect(o, a.i("x1", 0), a.i("y1", 0), a.i("x2", 0), a.i("y2", 0), c, a.i("thick", 1))
        save(o, a.out)
    else:
        return False
    return True


def run(mut a: Args) raises -> Bool:
    if a.op == "groupRectangles":
        var m = load[DType.int32](a.ins[0])
        var rl = List[Int]()
        for v in m.data:
            rl.append(Int(v))
        var g = List[Int]()
        while a.again():
            g = group_rects(rl, a.i("thresh", 2))
        var o = Mat[DType.int32](len(g) // 4, 4, 1)
        for i in range(len(g)):
            o.data[i] = Int32(g[i])
        save(o, a.out)
        return True
    if a.op in ["connectedComponentsWithStats", "Canny", "findContours", "goodFeaturesToTrack", "line", "rectangle", "HOGScores", "detectMultiScale", "grabCut"]:
        return run_u8(a)
    if not (a.op in ["GaussianBlur", "pyrDown", "Sobel", "threshold", "integral", "erode", "dilate", "cvtColor", "resize", "warpAffine", "remap", "blobFromImage"]):
        return False
    var code = peek_code(a.ins[0])
    comptime for i in range(2):
        if code == i:
            return run_dt[DTS[i]](a)
    return False
