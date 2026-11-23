# hyper: ops taken from the 2023-2026 face and micro-expression papers (cards: mojo-cv-papers/cards/<arxiv id>.md).
#   flowDecomp   2409.05396  rigid (affine) head motion fitted to a dense flow, residual = expression flow
#   flowStrain   2603.07043  optical strain and magnitude of a flow, the onset-referenced micro-expression features
#   onsetFlow    2603.07043  Farneback flow from the onset frame to every later frame, one 2-channel pair per frame
#   flowEpe      2601.06479  mean end-point error, outlier share, count (optionally inside a mask)
#   flowReg      2601.06479  Sobel-gradient-masked flow smoothness: smoothness loss on texture-less pixels only (our reading
#                            of "masks and gradients from Sobel operators"; the paper gives no formula in the span read)
#   downUp       2310.10022  INTER_AREA down by f, bicubic back up: the low-resolution protocol
#   getPerspectiveTransform, warpPerspective, 2607.15995  four landmarks to a canonical face frame
#   eq2persp, persp2eq  2611.16793  equirectangular <-> pinhole views (remap grids, wrap in longitude)
#   lpq          2308.01700  local phase quantisation codes and histogram
#   evm          2606.25542  Eulerian magnification: spatial blur, temporal IIR band-pass, amplify, add back
from std.math import sqrt, floor, cos, sin, atan2, asin, tan
from mojocv.mat import Mat, load, save
from mojocv.core import Args, par
from mojocv.imgproc import resize, gaussian_blur, sobel, remap, F32
from mojocv.video import farneback

comptime F64 = DType.float64
comptime U8 = DType.uint8
comptime PI = 3.141592653589793
comptime TWO_PI = 6.283185307179586


def _solve(mut a: List[Float64], mut b: List[Float64], n: Int) raises -> List[Float64]:
    """Gaussian elimination with partial pivoting on the n x n system a x = b (a row-major, both destroyed)."""
    for c in range(n):
        var p = c
        for r in range(c + 1, n):
            if abs(a[r * n + c]) > abs(a[p * n + c]):
                p = r
        if abs(a[p * n + c]) < 1e-12:
            raise Error("mojocv: singular system (degenerate points or too few pixels)")
        if p != c:
            for k in range(n):
                var t = a[c * n + k]
                a[c * n + k] = a[p * n + k]
                a[p * n + k] = t
            var tb = b[c]
            b[c] = b[p]
            b[p] = tb
        for r in range(c + 1, n):
            var f = a[r * n + c] / a[c * n + c]
            for k in range(c, n):
                a[r * n + k] -= f * a[c * n + k]
            b[r] -= f * b[c]
    var x = List[Float64](length=n, fill=0.0)
    for r in range(n - 1, -1, -1):
        var s = b[r]
        for k in range(r + 1, n):
            s -= a[r * n + k] * x[k]
        x[r] = s / a[r * n + r]
    return x^


def _need_flow(f: Mat[F32], what: String) raises:
    if f.ch != 2 or f.rows < 2 or f.cols < 2:
        raise Error("mojocv: " + what + " needs a flow of at least 2 x 2 pixels with 2 channels, got " + String(f.rows) + "x" + String(f.cols) + "x" + String(f.ch))


def flow_decomp(flow: Mat[F32], mask: Mat[U8], iters: Int, thr: Float64) raises -> Tuple[Mat[F32], Mat[F64]]:
    """Fit u = a x + b y + c and v = d x + e y + f by least squares (an empty `mask` means every pixel), refit `iters` - 1 more
    times on the pixels whose previous residual is at most `thr` px (trimmed fit, so the expression flow does not drag the head
    motion), and return (residual flow = flow - fit, 2 x 3 parameters in pixel coordinates)."""
    _need_flow(flow, "flowDecomp")
    var has = mask.rows > 0
    if has and (mask.rows != flow.rows or mask.cols != flow.cols or mask.ch != 1):
        raise Error("mojocv: flowDecomp: mask must be 1-channel and the shape of the flow")
    if iters < 1 or (iters > 1 and thr <= 0.0):
        raise Error("mojocv: flowDecomp: iters >= 1 and, for iters > 1, thr > 0")
    var rows = flow.rows
    var cols = flow.cols
    var n = rows * cols
    var cx = Float64(cols - 1) * 0.5
    var cy = Float64(rows - 1) * 0.5
    var base = List[Bool](length=n, fill=True)
    if has:
        for i in range(n):
            base[i] = mask.data[i] != 0
    var use = base.copy()
    var p = List[Float64](length=6, fill=0.0)
    for it in range(iters):
        var A = List[Float64](length=9, fill=0.0)
        var bu = List[Float64](length=3, fill=0.0)
        var bv = List[Float64](length=3, fill=0.0)
        var cnt = 0
        for y in range(rows):
            var yy = Float64(y) - cy
            for x in range(cols):
                var i = y * cols + x
                if not use[i]:
                    continue
                var xx = Float64(x) - cx
                var u = Float64(flow.data[2 * i])
                var v = Float64(flow.data[2 * i + 1])
                A[0] += xx * xx
                A[1] += xx * yy
                A[2] += xx
                A[4] += yy * yy
                A[5] += yy
                A[8] += 1.0
                bu[0] += xx * u
                bu[1] += yy * u
                bu[2] += u
                bv[0] += xx * v
                bv[1] += yy * v
                bv[2] += v
                cnt += 1
        if cnt < 3:
            raise Error("mojocv: flowDecomp: fewer than 3 pixels left to fit")
        A[3] = A[1]
        A[6] = A[2]
        A[7] = A[5]
        var A2 = A.copy()
        var pu = _solve(A, bu, 3)
        var pv = _solve(A2, bv, 3)
        for k in range(3):
            p[k] = pu[k]
            p[3 + k] = pv[k]
        if it + 1 < iters:
            for y in range(rows):
                var yy = Float64(y) - cy
                for x in range(cols):
                    var i = y * cols + x
                    var xx = Float64(x) - cx
                    var ru = Float64(flow.data[2 * i]) - (p[0] * xx + p[1] * yy + p[2])
                    var rv = Float64(flow.data[2 * i + 1]) - (p[3] * xx + p[4] * yy + p[5])
                    use[i] = base[i] and sqrt(ru * ru + rv * rv) <= thr
    var res = Mat[F32](rows, cols, 2, False)
    for y in range(rows):
        var yy = Float64(y) - cy
        for x in range(cols):
            var i = y * cols + x
            var xx = Float64(x) - cx
            res.data[2 * i] = Float32(Float64(flow.data[2 * i]) - (p[0] * xx + p[1] * yy + p[2]))
            res.data[2 * i + 1] = Float32(Float64(flow.data[2 * i + 1]) - (p[3] * xx + p[4] * yy + p[5]))
    var par6 = Mat[F64](2, 3, 1)
    par6.data[0] = p[0]
    par6.data[1] = p[1]
    par6.data[2] = p[2] - p[0] * cx - p[1] * cy
    par6.data[3] = p[3]
    par6.data[4] = p[4]
    par6.data[5] = p[5] - p[3] * cx - p[4] * cy
    return (res^, par6^)


def flow_strain(flow: Mat[F32]) raises -> Tuple[Mat[F32], Mat[F32]]:
    """(optical strain sqrt(exx^2 + eyy^2 + 2 exy^2), flow magnitude), both rows x cols x 1. Central differences inside,
    one-sided at the border (numpy.gradient)."""
    _need_flow(flow, "flowStrain")
    var rows = flow.rows
    var cols = flow.cols
    var s = Mat[F32](rows, cols, 1, False)
    var m = Mat[F32](rows, cols, 1, False)
    for y in range(rows):
        var yl = max(y - 1, 0)
        var yr = min(y + 1, rows - 1)
        var dy = Float64(yr - yl)
        for x in range(cols):
            var xl = max(x - 1, 0)
            var xr = min(x + 1, cols - 1)
            var dx = Float64(xr - xl)
            var i = y * cols + x
            var il = y * cols + xl
            var ir = y * cols + xr
            var iu = yl * cols + x
            var id = yr * cols + x
            var ux = (Float64(flow.data[2 * ir]) - Float64(flow.data[2 * il])) / dx
            var vx = (Float64(flow.data[2 * ir + 1]) - Float64(flow.data[2 * il + 1])) / dx
            var uy = (Float64(flow.data[2 * id]) - Float64(flow.data[2 * iu])) / dy
            var vy = (Float64(flow.data[2 * id + 1]) - Float64(flow.data[2 * iu + 1])) / dy
            var exy = 0.5 * (uy + vx)
            s.data[i] = Float32(sqrt(ux * ux + vy * vy + 2.0 * exy * exy))
            var u = Float64(flow.data[2 * i])
            var v = Float64(flow.data[2 * i + 1])
            m.data[i] = Float32(sqrt(u * u + v * v))
    return (s^, m^)


def flow_epe(pred: Mat[F32], gt: Mat[F32], mask: Mat[U8]) raises -> Mat[F64]:
    """1 x 3: mean end-point error, share of pixels with error > 1 px, pixel count (inside `mask` when it is not empty)."""
    _need_flow(pred, "flowEpe")
    if not pred.same_shape(gt):
        raise Error("mojocv: flowEpe: the two flows differ in shape")
    var has = mask.rows > 0
    if has and (mask.rows != pred.rows or mask.cols != pred.cols or mask.ch != 1):
        raise Error("mojocv: flowEpe: mask must be 1-channel and the shape of the flow")
    var n = pred.rows * pred.cols
    var s = 0.0
    var bad = 0
    var cnt = 0
    for i in range(n):
        if has and mask.data[i] == 0:
            continue
        var du = Float64(pred.data[2 * i]) - Float64(gt.data[2 * i])
        var dv = Float64(pred.data[2 * i + 1]) - Float64(gt.data[2 * i + 1])
        var e = sqrt(du * du + dv * dv)
        s += e
        if e > 1.0:
            bad += 1
        cnt += 1
    if cnt == 0:
        raise Error("mojocv: flowEpe: the mask selects no pixel")
    var o = Mat[F64](1, 3, 1)
    o.data[0] = s / Float64(cnt)
    o.data[1] = Float64(bad) / Float64(cnt)
    o.data[2] = Float64(cnt)
    return o^


def flow_reg(img: Mat[U8], flow: Mat[F32], thr: Float64) raises -> Mat[F64]:
    """1 x 3: mean |forward difference| of u and v (x and y) over the texture-less pixels (Sobel magnitude of the grey frame
    < thr) that have both forward neighbours, the share of such pixels, the mean Sobel magnitude of the frame."""
    _need_flow(flow, "flowReg")
    if img.ch != 1 or img.rows != flow.rows or img.cols != flow.cols:
        raise Error("mojocv: flowReg: needs a 1-channel frame of the flow's shape")
    var rows = img.rows
    var cols = img.cols
    var gx = sobel[U8, F32](img, 1, 0, 3, 1.0)
    var gy = sobel[U8, F32](img, 0, 1, 3, 1.0)
    var s = 0.0
    var cnt = 0
    var gsum = 0.0
    for y in range(rows):
        for x in range(cols):
            var i = y * cols + x
            var a = Float64(gx.data[i])
            var b = Float64(gy.data[i])
            var g = sqrt(a * a + b * b)
            gsum += g
            if g < thr and x + 1 < cols and y + 1 < rows:
                var r = i + 1
                var d = i + cols
                var t = abs(Float64(flow.data[2 * r]) - Float64(flow.data[2 * i]))
                t += abs(Float64(flow.data[2 * d]) - Float64(flow.data[2 * i]))
                t += abs(Float64(flow.data[2 * r + 1]) - Float64(flow.data[2 * i + 1]))
                t += abs(Float64(flow.data[2 * d + 1]) - Float64(flow.data[2 * i + 1]))
                s += t
                cnt += 1
    var o = Mat[F64](1, 3, 1)
    o.data[0] = s / Float64(max(cnt, 1))
    o.data[1] = Float64(cnt) / Float64((rows - 1) * (cols - 1))
    o.data[2] = gsum / Float64(rows * cols)
    return o^


def down_up[dt: DType](src: Mat[dt], f: Int, down_kind: Int, up_kind: Int) raises -> Mat[dt]:
    """resize by 1/f with `down_kind` (4 = INTER_AREA) and back to the source size with `up_kind` (2 = bicubic)."""
    if f < 1:
        raise Error("mojocv: downUp: factor must be >= 1")
    var w = max(1, (src.cols + f // 2) // f)
    var h = max(1, (src.rows + f // 2) // f)
    var small = resize[dt](src, w, h, down_kind)
    return resize[dt](small, src.cols, src.rows, up_kind)


def _pts4(m: Mat[F64], what: String) raises:
    if m.rows != 4 or m.cols != 2 or m.ch != 1:
        raise Error("mojocv: " + what + " needs 4 x 2 points")


def perspective4(src: Mat[F64], dst: Mat[F64]) raises -> Mat[F64]:
    """cv2.getPerspectiveTransform: the 3 x 3 H (h33 = 1) with H (src_i, 1) ~ (dst_i, 1)."""
    _pts4(src, "getPerspectiveTransform")
    _pts4(dst, "getPerspectiveTransform")
    var A = List[Float64](length=64, fill=0.0)
    var b = List[Float64](length=8, fill=0.0)
    for i in range(4):
        var x = src.data[2 * i]
        var y = src.data[2 * i + 1]
        var X = dst.data[2 * i]
        var Y = dst.data[2 * i + 1]
        var r = 2 * i
        A[r * 8 + 0] = x
        A[r * 8 + 1] = y
        A[r * 8 + 2] = 1.0
        A[r * 8 + 6] = -x * X
        A[r * 8 + 7] = -y * X
        b[r] = X
        r += 1
        A[r * 8 + 3] = x
        A[r * 8 + 4] = y
        A[r * 8 + 5] = 1.0
        A[r * 8 + 6] = -x * Y
        A[r * 8 + 7] = -y * Y
        b[r] = Y
    var h = _solve(A, b, 8)
    var o = Mat[F64](3, 3, 1)
    for k in range(8):
        o.data[k] = h[k]
    o.data[8] = 1.0
    return o^


def _inv3(m: Mat[F64]) raises -> Mat[F64]:
    var a = m.data.copy()
    var det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
    if abs(det) < 1e-300:
        raise Error("mojocv: warpPerspective: singular matrix")
    var o = Mat[F64](3, 3, 1)
    o.data[0] = (a[4] * a[8] - a[5] * a[7]) / det
    o.data[1] = (a[2] * a[7] - a[1] * a[8]) / det
    o.data[2] = (a[1] * a[5] - a[2] * a[4]) / det
    o.data[3] = (a[5] * a[6] - a[3] * a[8]) / det
    o.data[4] = (a[0] * a[8] - a[2] * a[6]) / det
    o.data[5] = (a[2] * a[3] - a[0] * a[5]) / det
    o.data[6] = (a[3] * a[7] - a[4] * a[6]) / det
    o.data[7] = (a[1] * a[6] - a[0] * a[7]) / det
    o.data[8] = (a[0] * a[4] - a[1] * a[3]) / det
    return o^


def warp_perspective(src: Mat[U8], m: Mat[F64], w: Int, h: Int, inverse: Bool, bval: Float64) raises -> Mat[U8]:
    """cv2.warpPerspective, bilinear, constant border. `inverse` True: m maps destination to source (WARP_INVERSE_MAP).
    The coordinates go through float32 maps and imgproc.remap."""
    if m.rows != 3 or m.cols != 3 or w < 1 or h < 1:
        raise Error("mojocv: warpPerspective needs a 3 x 3 matrix and a positive size")
    var im = Mat[F64](copy=m) if inverse else _inv3(m)
    var mx = Mat[F32](h, w, 1, False)
    var my = Mat[F32](h, w, 1, False)
    var pmx = mx.ptr()
    var pmy = my.ptr()
    var pm = im.ptr()

    def row(y: Int) {imm}:
        for x in range(w):
            var den = pm[unsafe_offset=6] * Float64(x) + pm[unsafe_offset=7] * Float64(y) + pm[unsafe_offset=8]
            var k = 1.0 / den if den != 0.0 else 0.0
            pmx[unsafe_offset=y * w + x] = Float32((pm[unsafe_offset=0] * Float64(x) + pm[unsafe_offset=1] * Float64(y) + pm[unsafe_offset=2]) * k)
            pmy[unsafe_offset=y * w + x] = Float32((pm[unsafe_offset=3] * Float64(x) + pm[unsafe_offset=4] * Float64(y) + pm[unsafe_offset=5]) * k)

    par(row, h)
    _ = (mx.rows, my.rows, im.rows)
    return remap[U8](src, mx, my, 1, 2, bval)


def _wrap_cols(src: Mat[U8]) -> Mat[U8]:
    """One column of the opposite edge on each side: bilinear reads one pixel beyond the seam of an equirectangular picture."""
    var o = Mat[U8](src.rows, src.cols + 2, src.ch, False)
    for y in range(src.rows):
        for x in range(-1, src.cols + 1):
            var sx = (x + src.cols) % src.cols
            for k in range(src.ch):
                o.data[(y * (src.cols + 2) + x + 1) * src.ch + k] = src.data[(y * src.cols + sx) * src.ch + k]
    return o^


def eq2persp(src: Mat[U8], fov: Float64, yaw: Float64, pitch: Float64, w: Int, h: Int) raises -> Mat[U8]:
    """Pinhole view (horizontal field of view `fov` degrees, yaw right and pitch down in degrees) of an equirectangular
    picture; bilinear, wrap in longitude, replicate at the poles."""
    if fov <= 0.0 or fov >= 180.0 or w < 1 or h < 1:
        raise Error("mojocv: eq2persp: 0 < fov < 180 and a positive size")
    var f = 0.5 * Float64(w) / tan(fov * PI / 360.0)
    var sy = sin(yaw * PI / 180.0)
    var cyw = cos(yaw * PI / 180.0)
    var sp = sin(pitch * PI / 180.0)
    var cp = cos(pitch * PI / 180.0)
    var mx = Mat[F32](h, w, 1, False)
    var my = Mat[F32](h, w, 1, False)
    var pad = _wrap_cols(src)
    var W = Float64(src.cols)
    var H = Float64(src.rows)
    var pmx = mx.ptr()
    var pmy = my.ptr()

    def row(v: Int) {imm}:
        var y = (Float64(v) - Float64(h - 1) * 0.5) / f
        for u in range(w):
            var x = (Float64(u) - Float64(w - 1) * 0.5) / f
            var y1 = y * cp + sp
            var z1 = -y * sp + cp
            var x2 = x * cyw + z1 * sy
            var z2 = -x * sy + z1 * cyw
            var n = sqrt(x2 * x2 + y1 * y1 + z2 * z2)
            var lon = atan2(x2, z2)
            var lat = asin(y1 / n)
            pmx[unsafe_offset=v * w + u] = Float32((lon / TWO_PI + 0.5) * W - 0.5 + 1.0)
            pmy[unsafe_offset=v * w + u] = Float32((lat / PI + 0.5) * H - 0.5)

    par(row, h)
    _ = (mx.rows, my.rows)
    return remap[U8](pad, mx, my, 1, 1, 0.0)


def persp2eq(src: Mat[U8], fov: Float64, yaw: Float64, pitch: Float64, w: Int, h: Int) raises -> Mat[U8]:
    """The inverse of eq2persp: paint the pinhole picture `src` into a w x h equirectangular picture; black outside its view."""
    if fov <= 0.0 or fov >= 180.0 or w < 1 or h < 1:
        raise Error("mojocv: persp2eq: 0 < fov < 180 and a positive size")
    var f = 0.5 * Float64(src.cols) / tan(fov * PI / 360.0)
    var sy = sin(yaw * PI / 180.0)
    var cyw = cos(yaw * PI / 180.0)
    var sp = sin(pitch * PI / 180.0)
    var cp = cos(pitch * PI / 180.0)
    var mx = Mat[F32](h, w, 1, False)
    var my = Mat[F32](h, w, 1, False)
    var pmx = mx.ptr()
    var pmy = my.ptr()
    var hx = Float64(src.cols - 1) * 0.5
    var hy = Float64(src.rows - 1) * 0.5

    def row(j: Int) {imm}:
        var lat = ((Float64(j) + 0.5) / Float64(h) - 0.5) * PI
        var dy = sin(lat)
        var cl = cos(lat)
        for i in range(w):
            var lon = ((Float64(i) + 0.5) / Float64(w) - 0.5) * TWO_PI
            var dx = cl * sin(lon)
            var dz = cl * cos(lon)
            var x1 = dx * cyw - dz * sy
            var z1 = dx * sy + dz * cyw
            var y2 = dy * cp - z1 * sp
            var z2 = dy * sp + z1 * cp
            if z2 <= 1e-9:
                pmx[unsafe_offset=j * w + i] = -10.0
                pmy[unsafe_offset=j * w + i] = -10.0
            else:
                pmx[unsafe_offset=j * w + i] = Float32(f * x1 / z2 + hx)
                pmy[unsafe_offset=j * w + i] = Float32(f * y2 / z2 + hy)

    par(row, h)
    _ = (mx.rows, my.rows)
    return remap[U8](src, mx, my, 1, 2, 0.0)


def lpq(src: Mat[U8], win: Int) raises -> Tuple[Mat[U8], Mat[F64]]:
    """Local phase quantisation (Ojansivu and Heikkila): the STFT of each win x win window at the four lowest frequencies
    (a, 0), (0, a), (a, a), (a, -a), a = 1 / win, the signs of the 4 real and 4 imaginary parts as 8 bits (a part counts as
    positive above 1e-9, so flat windows code 0 in every implementation), no decorrelation. Returns the codes of the
    (rows - win + 1) x (cols - win + 1) valid area and the normalised 256-bin histogram."""
    if src.ch != 1:
        raise Error("mojocv: lpq needs a 1-channel image, got " + String(src.ch) + " channels")
    if win < 3 or win % 2 == 0 or win > src.rows or win > src.cols:
        raise Error("mojocv: lpq: window must be odd, at least 3 and inside the image")
    var r = win // 2
    var phi = TWO_PI / Float64(win)
    var oh = src.rows - win + 1
    var ow = src.cols - win + 1
    # All four frequencies are separable: e^{j phi (fx dx + fy dy)} is a product of a column factor and a row factor, so one
    # horizontal pass per source row gives A1 = sum f, Ac = sum f cos(phi dx), As = sum f sin(phi dx), and the vertical pass
    # combines win values per frequency (win^2 + 12 win operations per pixel instead of 8 win^2).
    var tr = Mat[F64](2, win, 1)
    for k in range(win):
        tr.data[k] = cos(phi * Float64(k - r))
        tr.data[win + k] = sin(phi * Float64(k - r))
    var codes = Mat[U8](oh, ow, 1, False)
    var pc = codes.ptr()
    var pk = tr.ptr()
    var ps = src.ptr()
    var cols = src.cols
    comptime BH = 32

    def band(b: Int) {imm}:
        var y0 = b * BH
        var y1 = min(y0 + BH, oh)
        var nr = y1 - y0 + win - 1
        var sc = Mat[F64](3 * nr, ow, 1, False)
        var pa = sc.ptr()
        for rr in range(nr):
            for x in range(ow):
                var s1 = 0.0
                var sc_ = 0.0
                var ss = 0.0
                for k in range(win):
                    var v = Float64(ps[unsafe_offset=(y0 + rr) * cols + x + k])
                    s1 += v
                    sc_ += v * pk[unsafe_offset=k]
                    ss += v * pk[unsafe_offset=win + k]
                pa[unsafe_offset=rr * ow + x] = s1
                pa[unsafe_offset=(nr + rr) * ow + x] = sc_
                pa[unsafe_offset=(2 * nr + rr) * ow + x] = ss
        for y in range(y0, y1):
            for x in range(ow):
                var re2 = 0.0
                var im2 = 0.0
                var re1 = 0.0
                var im1 = 0.0
                var re3 = 0.0
                var im3 = 0.0
                var re4 = 0.0
                var im4 = 0.0
                for k in range(win):
                    var rr = y - y0 + k
                    var a1 = pa[unsafe_offset=rr * ow + x]
                    var ac = pa[unsafe_offset=(nr + rr) * ow + x]
                    var as_ = pa[unsafe_offset=(2 * nr + rr) * ow + x]
                    var c = pk[unsafe_offset=k]
                    var s = pk[unsafe_offset=win + k]
                    re1 += ac
                    im1 += as_
                    re2 += a1 * c
                    im2 += a1 * s
                    re3 += ac * c - as_ * s
                    im3 += ac * s + as_ * c
                    re4 += ac * c + as_ * s
                    im4 += as_ * c - ac * s
                var code = 0
                if re1 > 1e-9:
                    code |= 1
                if im1 > 1e-9:
                    code |= 2
                if re2 > 1e-9:
                    code |= 4
                if im2 > 1e-9:
                    code |= 8
                if re3 > 1e-9:
                    code |= 16
                if im3 > 1e-9:
                    code |= 32
                if re4 > 1e-9:
                    code |= 64
                if im4 > 1e-9:
                    code |= 128
                pc[unsafe_offset=y * ow + x] = UInt8(code)
        _ = sc.rows

    par(band, (oh + BH - 1) // BH)
    _ = (codes.rows, tr.rows, src.rows)
    var hist = Mat[F64](1, 256, 1)
    for i in range(oh * ow):
        hist.data[Int(codes.data[i])] += 1.0
    for k in range(256):
        hist.data[k] /= Float64(oh * ow)
    return (codes^, hist^)


def evm(stack: Mat[F32], alpha: Float64, lo: Float64, hi: Float64, sigma: Float64) raises -> Mat[F32]:
    """Eulerian video magnification (Wu et al. 2012) of a grey clip stored as one channel per frame: each frame blurred by a
    Gaussian of `sigma` (0 = none), per pixel two first-order IIR low-passes with coefficients hi > lo (started on frame 0),
    out_t = in_t + alpha (L_hi - L_lo)."""
    var t_n = stack.ch
    if t_n < 2:
        raise Error("mojocv: evm needs a stack of at least 2 frames (one channel each)")
    if not (0.0 < lo and lo < hi and hi <= 1.0):
        raise Error("mojocv: evm: need 0 < lo < hi <= 1")
    var rows = stack.rows
    var cols = stack.cols
    var sm = Mat[F32](copy=stack) if sigma <= 0.0 else Mat[F32](rows, cols, t_n, False)
    if sigma > 0.0:
        for t in range(t_n):
            var fr = Mat[F32](rows, cols, 1, False)
            for i in range(rows * cols):
                fr.data[i] = stack.data[i * t_n + t]
            var b = gaussian_blur[F32](fr, 0, sigma)
            for i in range(rows * cols):
                sm.data[i * t_n + t] = b.data[i]
    var o = Mat[F32](rows, cols, t_n, False)
    for i in range(rows * cols):
        var l1 = Float64(sm.data[i * t_n])
        var l2 = l1
        for t in range(t_n):
            var s = Float64(sm.data[i * t_n + t])
            l1 += hi * (s - l1)
            l2 += lo * (s - l2)
            o.data[i * t_n + t] = Float32(Float64(stack.data[i * t_n + t]) + alpha * (l1 - l2))
    return o^


def _need(a: Args, n: Int) raises:
    if len(a.ins) < n:
        raise Error("mojocv: " + a.op + " needs " + String(n) + " input file(s), got " + String(len(a.ins)))


def run(mut a: Args) raises -> Bool:
    if a.op == "flowDecomp":
        _need(a, 1)
        var fl = load[F32](a.ins[0])
        var mk = load[U8](a.ins[1]) if len(a.ins) > 1 else Mat[U8](0, 0)
        var r = (Mat[F32](0, 0), Mat[F64](0, 0))
        while a.again():
            r = flow_decomp(fl, mk, a.i("iters", 1), a.f("thr", 1.0))
        save(r[0], a.out)
        save(r[1], a.out + ".1")
    elif a.op == "flowStrain":
        _need(a, 1)
        var fl = load[F32](a.ins[0])
        var r = (Mat[F32](0, 0), Mat[F32](0, 0))
        while a.again():
            r = flow_strain(fl)
        save(r[0], a.out)
        save(r[1], a.out + ".1")
    elif a.op == "onsetFlow":
        _need(a, 2)
        var on = load[U8](a.ins[0])
        var k = len(a.ins) - 1
        var o = Mat[F32](on.rows, on.cols, 2 * k, False)
        while a.again():
            for j in range(k):
                var fr = load[U8](a.ins[1 + j])
                var fl = farneback(on, fr, a.f("pyrScale", 0.5), a.i("levels", 3), a.i("winsize", 15), a.i("iters", 3), a.i("polyN", 5), a.f("polySigma", 1.2))
                for i in range(on.rows * on.cols):
                    o.data[i * 2 * k + 2 * j] = fl.data[2 * i]
                    o.data[i * 2 * k + 2 * j + 1] = fl.data[2 * i + 1]
        save(o, a.out)
    elif a.op == "flowEpe":
        _need(a, 2)
        var p = load[F32](a.ins[0])
        var g = load[F32](a.ins[1])
        var mk = load[U8](a.ins[2]) if len(a.ins) > 2 else Mat[U8](0, 0)
        var o = Mat[F64](0, 0)
        while a.again():
            o = flow_epe(p, g, mk)
        save(o, a.out)
    elif a.op == "flowReg":
        _need(a, 2)
        var im = load[U8](a.ins[0])
        var fl = load[F32](a.ins[1])
        var o = Mat[F64](0, 0)
        while a.again():
            o = flow_reg(im, fl, a.f("thr", 40.0))
        save(o, a.out)
    elif a.op == "downUp":
        _need(a, 1)
        var m = load[U8](a.ins[0])
        var o = Mat[U8](0, 0)
        while a.again():
            o = down_up[U8](m, a.i("f", 4), a.i("down", 4), a.i("up", 2))
        save(o, a.out)
    elif a.op == "getPerspectiveTransform":
        _need(a, 2)
        var s = load[F64](a.ins[0])
        var d = load[F64](a.ins[1])
        var o = Mat[F64](0, 0)
        while a.again():
            o = perspective4(s, d)
        save(o, a.out)
    elif a.op == "warpPerspective":
        _need(a, 2)
        var m = load[U8](a.ins[0])
        var h = load[F64](a.ins[1])
        var o = Mat[U8](0, 0)
        while a.again():
            o = warp_perspective(m, h, a.i("w", m.cols), a.i("h", m.rows), a.i("inv", 0) != 0, a.f("bval", 0.0))
        save(o, a.out)
    elif a.op == "eq2persp" or a.op == "persp2eq":
        _need(a, 1)
        var m = load[U8](a.ins[0])
        var o = Mat[U8](0, 0)
        while a.again():
            if a.op == "eq2persp":
                o = eq2persp(m, a.f("fov", 90.0), a.f("yaw", 0.0), a.f("pitch", 0.0), a.i("w", 640), a.i("h", 480))
            else:
                o = persp2eq(m, a.f("fov", 90.0), a.f("yaw", 0.0), a.f("pitch", 0.0), a.i("w", 1024), a.i("h", 512))
        save(o, a.out)
    elif a.op == "lpq":
        _need(a, 1)
        var m = load[U8](a.ins[0])
        var r = (Mat[U8](0, 0), Mat[F64](0, 0))
        while a.again():
            r = lpq(m, a.i("win", 7))
        save(r[0], a.out)
        save(r[1], a.out + ".1")
    elif a.op == "evm":
        _need(a, 1)
        var s = load[F32](a.ins[0])
        var o = Mat[F32](0, 0)
        while a.again():
            o = evm(s, a.f("alpha", 20.0), a.f("lo", 0.05), a.f("hi", 0.4), a.f("sigma", 0.0))
        save(o, a.out)
    else:
        return False
    return True
