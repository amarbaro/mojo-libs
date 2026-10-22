# video: sub-pixel corner refinement and sparse pyramidal Lucas-Kanade optical flow (Bouguet 2000) with cv2's
# fixed-point window arithmetic, and dense Farneback flow.
from std.sys.info import simd_width_of
from std.math import sqrt, exp, floor
from max.algorithm import parallelize
from mojocv.mat import Mat, load, save
from mojocv.core import Args
from mojocv.imgproc import pyr_down, pad, ptr_of, rint, bidx, Ptr, F32


def sub_pix(src: Mat[DType.uint8], cx: Float32, cy: Float32, w: Int, h: Int, mut out: List[Float32]):
    """cv2.getRectSubPix on an 8-bit image: a w x h patch centred on (cx, cy), bilinear, replicated border."""
    var x0 = cx - Float32(w - 1) * 0.5
    var y0 = cy - Float32(h - 1) * 0.5
    var ix = Int(floor(x0))
    var iy = Int(floor(y0))
    var a = x0 - Float32(ix)
    var b = y0 - Float32(iy)
    for y in range(h):
        for x in range(w):
            var xa = min(max(ix + x, 0), src.cols - 1)
            var xb = min(max(ix + x + 1, 0), src.cols - 1)
            var ya = min(max(iy + y, 0), src.rows - 1)
            var yb = min(max(iy + y + 1, 0), src.rows - 1)
            var s00 = Float32(src.at(ya, xa))
            var s01 = Float32(src.at(ya, xb))
            var s10 = Float32(src.at(yb, xa))
            var s11 = Float32(src.at(yb, xb))
            out[y * w + x] = (s00 * (1 - a) + s01 * a) * (1 - b) + (s10 * (1 - a) + s11 * a) * b


def corner_sub_pix(src: Mat[DType.uint8], pts: Mat[F32], win: Int, zero: Int, max_iter: Int, eps_in: Float64) -> Mat[F32]:
    """cv2.cornerSubPix: iterate the point to where the weighted gradient field is orthogonal to the offsets."""
    var o = Mat[F32](pts.rows, 2, 1)
    var wn = win * 2 + 1
    var mask = List[Float32](length=wn * wn, fill=0)
    for i in range(wn):
        var y = Float32(i - win) / Float32(win)
        var vy = Float32(exp(-y * y))
        for j in range(wn):
            var x = Float32(j - win) / Float32(win)
            mask[i * wn + j] = Float32(Float64(vy) * exp(Float64(-x * x)))
    if zero >= 0 and zero * 2 + 1 < wn:
        for i in range(win - zero, win + zero + 1):
            for j in range(win - zero, win + zero + 1):
                mask[i * wn + j] = 0
    var eps2 = eps_in * eps_in
    var iters = min(max(max_iter, 1), 100)
    var buf = List[Float32](length=(wn + 2) * (wn + 2), fill=0)
    for p in range(pts.rows):
        var tx = pts.at(p, 0)
        var ty = pts.at(p, 1)
        var cx = tx
        var cy = ty
        var it = 0
        var err = Float64(0)
        while True:
            sub_pix(src, cx, cy, wn + 2, wn + 2, buf)
            var a = Float64(0)
            var b = Float64(0)
            var c = Float64(0)
            var bb1 = Float64(0)
            var bb2 = Float64(0)
            for i in range(wn):
                var py = Float64(i - win)
                for j in range(wn):
                    var m = Float64(mask[i * wn + j])
                    var at = (i + 1) * (wn + 2) + j + 1
                    var tgx = Float64(buf[at + 1] - buf[at - 1])
                    var tgy = Float64(buf[at + wn + 2] - buf[at - wn - 2])
                    var gxx = tgx * tgx * m
                    var gxy = tgx * tgy * m
                    var gyy = tgy * tgy * m
                    var px = Float64(j - win)
                    a += gxx
                    b += gxy
                    c += gyy
                    bb1 += gxx * px + gxy * py
                    bb2 += gxy * px + gyy * py
            var det = a * c - b * b
            if abs(det) <= 2.220446049250313e-16 * 2.220446049250313e-16:
                break
            var scale = 1.0 / det
            var nx = Float32(Float64(cx) + c * scale * bb1 - b * scale * bb2)
            var ny = Float32(Float64(cy) - b * scale * bb1 + a * scale * bb2)
            err = Float64((nx - cx) * (nx - cx) + (ny - cy) * (ny - cy))
            cx = nx
            cy = ny
            if cx < 0 or cx >= Float32(src.cols) or cy < 0 or cy >= Float32(src.rows):
                break
            it += 1
            if not (it < iters and err > eps2):
                break
        if abs(cx - tx) > Float32(win) or abs(cy - ty) > Float32(win):
            cx = tx
            cy = ty
        o.set(p, 0, 0, cx)
        o.set(p, 1, 0, cy)
    return o^


# ---- Lucas-Kanade -----------------------------------------------------------------------------------------


struct Level(Movable):
    """One pyramid level: image and Scharr derivatives, both with a border of `b` pixels (reflect101)."""

    var img: Mat[DType.uint8]
    var dx: Mat[DType.int16]
    var dy: Mat[DType.int16]
    var rows: Int
    var cols: Int

    def __init__(out self, base: Mat[DType.uint8], border: Int):
        self.rows = base.rows
        self.cols = base.cols
        self.img = pad(base, border, border)
        self.dx = Mat[DType.int16](self.img.rows, self.img.cols, 1)
        self.dy = Mat[DType.int16](self.img.rows, self.img.cols, 1)
        var r = base.rows
        var c = base.cols
        # Scharr derivatives of the unpadded image (reflect101); the border of the derivative images stays zero, as in cv2
        for y in range(r):
            for x in range(c):
                var ya = bidx(y - 1, r, 0)
                var yb = bidx(y + 1, r, 0)
                var xa = bidx(x - 1, c, 0)
                var xb = bidx(x + 1, c, 0)
                var vxa = Int(base.at(ya, xa)) * 3 + Int(base.at(y, xa)) * 10 + Int(base.at(yb, xa)) * 3
                var vxb = Int(base.at(ya, xb)) * 3 + Int(base.at(y, xb)) * 10 + Int(base.at(yb, xb)) * 3
                self.dx.set(y + border, x + border, 0, Int16(vxb - vxa))
                var vya = Int(base.at(ya, xa)) * 3 + Int(base.at(ya, x)) * 10 + Int(base.at(ya, xb)) * 3
                var vyb = Int(base.at(yb, xa)) * 3 + Int(base.at(yb, x)) * 10 + Int(base.at(yb, xb)) * 3
                self.dy.set(y + border, x + border, 0, Int16(vyb - vya))


def descale(x: Int, n: Int) -> Int:
    return (x + (1 << (n - 1))) >> n


def lk_flow(prev: Mat[DType.uint8], nxt: Mat[DType.uint8], pts: Mat[F32], win: Int, max_level: Int, max_count: Int, eps: Float32) -> Tuple[Mat[F32], Mat[DType.uint8], Mat[F32]]:
    """cv2.calcOpticalFlowPyrLK: new positions (n, 2), status (n, 1), error (n, 1)."""
    var border = win + 1
    var pa = List[Level]()
    var pb = List[Level]()
    var ia = Mat[DType.uint8](copy=prev)
    var ib = Mat[DType.uint8](copy=nxt)
    var levels = 0
    for l in range(max_level + 1):
        pa.append(Level(ia, border))
        pb.append(Level(ib, border))
        levels = l
        if l == max_level or ia.rows < 2 * win or ia.cols < 2 * win:
            break
        ia = pyr_down(ia)
        ib = pyr_down(ib)
    var n = pts.rows
    var onext = Mat[F32](n, 2, 1)
    var ostat = Mat[DType.uint8](n, 1, 1)
    var oerr = Mat[F32](n, 1, 1)
    var half = Float32(win - 1) * 0.5
    var w2 = win * win
    comptime W_BITS = 14
    comptime FLT_SCALE = Float32(1.0 / Float64(1 << 20))
    for p in range(n):
        ostat.data[p] = 1
        var nx = Float32(0)
        var ny = Float32(0)
        var px0 = pts.at(p, 0)
        var py0 = pts.at(p, 1)
        for level in range(levels, -1, -1):
            var sc = Float32(1.0 / Float64(1 << level))
            var ppx = px0 * sc
            var ppy = py0 * sc
            if level == levels:
                nx = ppx
                ny = ppy
            else:
                nx = nx * 2
                ny = ny * 2
            ppx -= half
            ppy -= half
            var ipx = Int(floor(ppx))
            var ipy = Int(floor(ppy))
            ref lv = pa[level]
            ref lj = pb[level]
            if ipx < -win or ipx >= lv.cols or ipy < -win or ipy >= lv.rows:
                if level == 0:
                    ostat.data[p] = 0
                    oerr.data[p] = 0
                onext.set(p, 0, 0, nx)
                onext.set(p, 1, 0, ny)
                continue
            var a = ppx - Float32(ipx)
            var b = ppy - Float32(ipy)
            var iw00 = rint(Float64((1.0 - a) * (1.0 - b) * Float32(1 << W_BITS)))
            var iw01 = rint(Float64(a * (1.0 - b) * Float32(1 << W_BITS)))
            var iw10 = rint(Float64((1.0 - a) * b * Float32(1 << W_BITS)))
            var iw11 = (1 << W_BITS) - iw00 - iw01 - iw10
            var iwin = List[Int](length=w2, fill=0)
            var gx = List[Int](length=w2, fill=0)
            var gy = List[Int](length=w2, fill=0)
            var a11 = Float32(0)
            var a12 = Float32(0)
            var a22 = Float32(0)
            for y in range(win):
                for x in range(win):
                    var ry = y + ipy + border
                    var rx = x + ipx + border
                    var ival = descale(Int(lv.img.at(ry, rx)) * iw00 + Int(lv.img.at(ry, rx + 1)) * iw01 + Int(lv.img.at(ry + 1, rx)) * iw10 + Int(lv.img.at(ry + 1, rx + 1)) * iw11, W_BITS - 5)
                    var ix = descale(Int(lv.dx.at(ry, rx)) * iw00 + Int(lv.dx.at(ry, rx + 1)) * iw01 + Int(lv.dx.at(ry + 1, rx)) * iw10 + Int(lv.dx.at(ry + 1, rx + 1)) * iw11, W_BITS)
                    var iy = descale(Int(lv.dy.at(ry, rx)) * iw00 + Int(lv.dy.at(ry, rx + 1)) * iw01 + Int(lv.dy.at(ry + 1, rx)) * iw10 + Int(lv.dy.at(ry + 1, rx + 1)) * iw11, W_BITS)
                    iwin[y * win + x] = ival
                    gx[y * win + x] = ix
                    gy[y * win + x] = iy
                    a11 += Float32(ix * ix)
                    a12 += Float32(ix * iy)
                    a22 += Float32(iy * iy)
            a11 *= FLT_SCALE
            a12 *= FLT_SCALE
            a22 *= FLT_SCALE
            var d = a11 * a22 - a12 * a12
            var min_eig = (a22 + a11 - sqrt((a11 - a22) * (a11 - a22) + 4.0 * a12 * a12)) / Float32(2 * w2)
            if min_eig < 1e-4 or d < 1.1920929e-07:
                if level == 0:
                    ostat.data[p] = 0
                onext.set(p, 0, 0, nx)
                onext.set(p, 1, 0, ny)
                continue
            d = 1.0 / d
            nx -= half
            ny -= half
            var pdx = Float32(0)
            var pdy = Float32(0)
            for j in range(max_count):
                var inx = Int(floor(nx))
                var iny = Int(floor(ny))
                if inx < -win or inx >= lj.cols or iny < -win or iny >= lj.rows:
                    if level == 0:
                        ostat.data[p] = 0
                    break
                a = nx - Float32(inx)
                b = ny - Float32(iny)
                iw00 = rint(Float64((1.0 - a) * (1.0 - b) * Float32(1 << W_BITS)))
                iw01 = rint(Float64(a * (1.0 - b) * Float32(1 << W_BITS)))
                iw10 = rint(Float64((1.0 - a) * b * Float32(1 << W_BITS)))
                iw11 = (1 << W_BITS) - iw00 - iw01 - iw10
                var b1 = Float32(0)
                var b2 = Float32(0)
                for y in range(win):
                    for x in range(win):
                        var ry = y + iny + border
                        var rx = x + inx + border
                        var diff = descale(Int(lj.img.at(ry, rx)) * iw00 + Int(lj.img.at(ry, rx + 1)) * iw01 + Int(lj.img.at(ry + 1, rx)) * iw10 + Int(lj.img.at(ry + 1, rx + 1)) * iw11, W_BITS - 5) - iwin[y * win + x]
                        b1 += Float32(diff * gx[y * win + x])
                        b2 += Float32(diff * gy[y * win + x])
                b1 *= FLT_SCALE
                b2 *= FLT_SCALE
                var ddx = (a12 * b2 - a22 * b1) * d
                var ddy = (a12 * b1 - a11 * b2) * d
                nx += ddx
                ny += ddy
                if ddx * ddx + ddy * ddy <= eps:
                    break
                if j > 0 and abs(ddx + pdx) < 0.01 and abs(ddy + pdy) < 0.01:
                    nx -= ddx * 0.5
                    ny -= ddy * 0.5
                    break
                pdx = ddx
                pdy = ddy
            nx += half
            ny += half
            if level == 0 and ostat.data[p] != 0:
                var fx = nx - half
                var fy = ny - half
                var ifx = Int(floor(fx))
                var ify = Int(floor(fy))
                if ifx < -win or ifx >= lj.cols or ify < -win or ify >= lj.rows:
                    ostat.data[p] = 0
                else:
                    var aa = fx - Float32(ifx)
                    var bb = fy - Float32(ify)
                    var w00 = rint(Float64((1.0 - aa) * (1.0 - bb) * Float32(1 << W_BITS)))
                    var w01 = rint(Float64(aa * (1.0 - bb) * Float32(1 << W_BITS)))
                    var w10 = rint(Float64((1.0 - aa) * bb * Float32(1 << W_BITS)))
                    var w11 = (1 << W_BITS) - w00 - w01 - w10
                    var errv = Float32(0)
                    for y in range(win):
                        for x in range(win):
                            var ry = y + ify + border
                            var rx = x + ifx + border
                            var diff = descale(Int(lj.img.at(ry, rx)) * w00 + Int(lj.img.at(ry, rx + 1)) * w01 + Int(lj.img.at(ry + 1, rx)) * w10 + Int(lj.img.at(ry + 1, rx + 1)) * w11, W_BITS - 5) - iwin[y * win + x]
                            errv += Float32(abs(diff))
                    oerr.data[p] = errv / Float32(32 * w2)
            onext.set(p, 0, 0, nx)
            onext.set(p, 1, 0, ny)
    return (onext^, ostat^, oerr^)


def run(mut a: Args) raises -> Bool:
    if a.op == "cornerSubPix":
        var im = load[DType.uint8](a.ins[0])
        var pts = load[F32](a.ins[1])
        var o = Mat[F32](0, 0)
        while a.again():
            o = corner_sub_pix(im, pts, a.i("win", 5), a.i("zero", -1), a.i("maxIter", 30), a.f("eps", 0.01))
        save(o, a.out)
    elif a.op == "calcOpticalFlowPyrLK":
        var p0 = load[DType.uint8](a.ins[0])
        var p1 = load[DType.uint8](a.ins[1])
        var pts = load[F32](a.ins[2])
        var r = (Mat[F32](0, 0), Mat[DType.uint8](0, 0), Mat[F32](0, 0))
        while a.again():
            r = lk_flow(p0, p1, pts, a.i("win", 21), a.i("maxLevel", 3), a.i("maxCount", 30), Float32(a.f("eps", 0.01)))
        save(r[0], a.out)
        save(r[1], a.out + ".1")
        save(r[2], a.out + ".2")
    else:
        return False
    return True
