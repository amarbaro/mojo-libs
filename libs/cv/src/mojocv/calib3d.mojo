# calib3d: camera models, pose and epipolar geometry, rectification, stereo and fiducials, all on small float64
# matrices stored as Mat[float64] (rows x cols x 1). Conventions follow cv2 5.0: dist = (k1, k2, p1, p2[, k3[, k4,
# k5, k6[, s1, s2, s3, s4]]]), rvec/tvec map object to camera coordinates.
from std.math import sqrt, atan, atan2, tan, cos, sin, acos, floor
from max.algorithm import parallelize
from mojocv.mat import Mat, load, save
from mojocv.core import Args
from mojocv.imgproc import rint

comptime F64 = DType.float64
comptime Mx = Mat[F64]


# ---- small dense linear algebra ---------------------------------------------------------------------------


def mx(r: Int, c: Int) -> Mx:
    return Mx(r, c, 1)


def mx_from(v: List[Float64], r: Int, c: Int) -> Mx:
    var m = mx(r, c)
    for i in range(r * c):
        m.data[i] = v[i]
    return m^


def ident(n: Int) -> Mx:
    var m = mx(n, n)
    for i in range(n):
        m.set(i, i, 0, 1.0)
    return m^


def mt(a: Mx) -> Mx:
    var o = mx(a.cols, a.rows)
    for i in range(a.rows):
        for j in range(a.cols):
            o.set(j, i, 0, a.at(i, j))
    return o^


def mm(a: Mx, b: Mx) -> Mx:
    var o = mx(a.rows, b.cols)
    for i in range(a.rows):
        for k in range(a.cols):
            var v = a.at(i, k)
            for j in range(b.cols):
                o.data[i * b.cols + j] += v * b.at(k, j)
    return o^


def madd(a: Mx, b: Mx, s: Float64 = 1.0) -> Mx:
    var o = Mx(copy=a)
    for i in range(a.size()):
        o.data[i] += s * b.data[i]
    return o^


def mscale(a: Mx, s: Float64) -> Mx:
    var o = Mx(copy=a)
    for i in range(a.size()):
        o.data[i] *= s
    return o^


def fnorm(a: Mx) -> Float64:
    var s = Float64(0)
    for v in a.data:
        s += v * v
    return sqrt(s)


def solve(a_in: Mx, b_in: Mx) -> Mx:
    """Gauss-Jordan with partial pivoting; a is n x n, b is n x m."""
    var n = a_in.rows
    var a = Mx(copy=a_in)
    var b = Mx(copy=b_in)
    for c in range(n):
        var p = c
        for r in range(c + 1, n):
            if abs(a.at(r, c)) > abs(a.at(p, c)):
                p = r
        if p != c:
            for j in range(n):
                var t = a.at(c, j)
                a.set(c, j, 0, a.at(p, j))
                a.set(p, j, 0, t)
            for j in range(b.cols):
                var t = b.at(c, j)
                b.set(c, j, 0, b.at(p, j))
                b.set(p, j, 0, t)
        var d = a.at(c, c)
        if d == 0:
            continue
        for r in range(n):
            if r == c:
                continue
            var f = a.at(r, c) / d
            if f == 0:
                continue
            for j in range(n):
                a.data[r * n + j] -= f * a.at(c, j)
            for j in range(b.cols):
                b.data[r * b.cols + j] -= f * b.at(c, j)
    for r in range(n):
        var d = a.at(r, r)
        for j in range(b.cols):
            b.data[r * b.cols + j] = b.at(r, j) / d if d != 0 else 0.0
    return b^


def inv(a: Mx) -> Mx:
    return solve(a, ident(a.rows))


def eigh(a_in: Mx) -> Tuple[List[Float64], Mx]:
    """Jacobi eigen-decomposition of a symmetric matrix: ascending eigenvalues, eigenvectors in columns."""
    var n = a_in.rows
    var a = Mx(copy=a_in)
    var v = ident(n)
    for _ in range(100):
        var off = Float64(0)
        for i in range(n):
            for j in range(i + 1, n):
                off += a.at(i, j) * a.at(i, j)
        if off < 1e-300:
            break
        for p in range(n):
            for q in range(p + 1, n):
                var apq = a.at(p, q)
                if abs(apq) < 1e-300:
                    continue
                var th = (a.at(q, q) - a.at(p, p)) / (2 * apq)
                var t = 1.0 / (abs(th) + sqrt(th * th + 1)) * (1.0 if th >= 0 else -1.0)
                var c = 1.0 / sqrt(t * t + 1)
                var s = t * c
                for k in range(n):
                    var akp = a.at(k, p)
                    var akq = a.at(k, q)
                    a.set(k, p, 0, c * akp - s * akq)
                    a.set(k, q, 0, s * akp + c * akq)
                for k in range(n):
                    var apk = a.at(p, k)
                    var aqk = a.at(q, k)
                    a.set(p, k, 0, c * apk - s * aqk)
                    a.set(q, k, 0, s * apk + c * aqk)
                for k in range(n):
                    var vkp = v.at(k, p)
                    var vkq = v.at(k, q)
                    v.set(k, p, 0, c * vkp - s * vkq)
                    v.set(k, q, 0, s * vkp + c * vkq)
    var order = List[Int]()
    for i in range(n):
        order.append(i)
    for i in range(n):
        for j in range(i + 1, n):
            if a.at(order[j], order[j]) < a.at(order[i], order[i]):
                var t = order[i]
                order[i] = order[j]
                order[j] = t
    var vals = List[Float64]()
    var vecs = mx(n, n)
    for c in range(n):
        vals.append(a.at(order[c], order[c]))
        for r in range(n):
            vecs.set(r, c, 0, v.at(r, order[c]))
    return (vals^, vecs^)


def cross(a: List[Float64], b: List[Float64]) -> List[Float64]:
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def det3(a: Mx) -> Float64:
    return a.at(0, 0) * (a.at(1, 1) * a.at(2, 2) - a.at(1, 2) * a.at(2, 1)) - a.at(0, 1) * (a.at(1, 0) * a.at(2, 2) - a.at(1, 2) * a.at(2, 0)) + a.at(0, 2) * (a.at(1, 0) * a.at(2, 1) - a.at(1, 1) * a.at(2, 0))


# ---- Rodrigues --------------------------------------------------------------------------------------------


def rodrigues_vec(r: List[Float64]) -> Mx:
    """Rotation vector to matrix."""
    var th = sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2])
    if th < 2.220446049250313e-16:
        return ident(3)
    var c = cos(th)
    var s = sin(th)
    var c1 = 1.0 - c
    var x = r[0] / th
    var y = r[1] / th
    var z = r[2] / th
    return mx_from([c + c1 * x * x, c1 * x * y - s * z, c1 * x * z + s * y, c1 * y * x + s * z, c + c1 * y * y, c1 * y * z - s * x, c1 * z * x - s * y, c1 * z * y + s * x, c + c1 * z * z], 3, 3)


def rodrigues_mat(rm: Mx) -> List[Float64]:
    """Rotation matrix to vector (the nearest rotation first, through the polar factor of a Jacobi eigen-decomposition)."""
    var ev = eigh(mm(mt(rm), rm))
    var inv_sqrt = mx(3, 3)
    for k in range(3):
        for i in range(3):
            for j in range(3):
                inv_sqrt.data[i * 3 + j] += ev[1].at(i, k) * ev[1].at(j, k) / sqrt(ev[0][k])
    var r = mm(rm, inv_sqrt)
    var rx = r.at(2, 1) - r.at(1, 2)
    var ry = r.at(0, 2) - r.at(2, 0)
    var rz = r.at(1, 0) - r.at(0, 1)
    var s = sqrt((rx * rx + ry * ry + rz * rz) * 0.25)
    var c = (r.at(0, 0) + r.at(1, 1) + r.at(2, 2) - 1) * 0.5
    c = min(max(c, -1.0), 1.0)
    var th = acos(c)
    if s < 1e-5:
        if c > 0:
            return [0.0, 0.0, 0.0]
        var t = (r.at(0, 0) + 1) * 0.5
        var vx = sqrt(max(t, 0.0))
        t = (r.at(1, 1) + 1) * 0.5
        var vy = sqrt(max(t, 0.0)) * (-1.0 if r.at(0, 1) < 0 else 1.0)
        t = (r.at(2, 2) + 1) * 0.5
        var vz = sqrt(max(t, 0.0)) * (-1.0 if r.at(0, 2) < 0 else 1.0)
        if abs(vx) < abs(vy) and abs(vx) < abs(vz) and (r.at(1, 2) > 0) != (vy * vz > 0):
            vz = -vz
        var nn = sqrt(vx * vx + vy * vy + vz * vz)
        th = th / nn
        return [vx * th, vy * th, vz * th]
    var vth = 1.0 / (2.0 * s)
    vth *= th
    return [rx * vth, ry * vth, rz * vth]


# ---- camera model -----------------------------------------------------------------------------------------


def dist_at(d: Mx, i: Int) -> Float64:
    return d.data[i] if i < d.size() else 0.0


def distort(x: Float64, y: Float64, d: Mx) -> Tuple[Float64, Float64]:
    """Apply the radial, tangential and thin-prism terms to normalized coordinates."""
    var k1 = dist_at(d, 0)
    var k2 = dist_at(d, 1)
    var p1 = dist_at(d, 2)
    var p2 = dist_at(d, 3)
    var k3 = dist_at(d, 4)
    var k4 = dist_at(d, 5)
    var k5 = dist_at(d, 6)
    var k6 = dist_at(d, 7)
    var r2 = x * x + y * y
    var r4 = r2 * r2
    var r6 = r4 * r2
    var cd = (1 + k1 * r2 + k2 * r4 + k3 * r6) / (1 + k4 * r2 + k5 * r4 + k6 * r6)
    var xd = x * cd + 2 * p1 * x * y + p2 * (r2 + 2 * x * x) + dist_at(d, 8) * r2 + dist_at(d, 9) * r4
    var yd = y * cd + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y + dist_at(d, 10) * r2 + dist_at(d, 11) * r4
    return (xd, yd)


def fisheye_distort(x: Float64, y: Float64, d: Mx) -> Tuple[Float64, Float64]:
    var r = sqrt(x * x + y * y)
    var th = atan(r)
    var t2 = th * th
    var td = th * (1 + dist_at(d, 0) * t2 + dist_at(d, 1) * t2 * t2 + dist_at(d, 2) * t2 * t2 * t2 + dist_at(d, 3) * t2 * t2 * t2 * t2)
    var s = td / r if r > 1e-8 else 1.0
    return (x * s, y * s)


def project_points(obj: Mx, rvec: Mx, tvec: Mx, k: Mx, d: Mx, fisheye: Bool) -> Mx:
    var rm = rodrigues_vec([rvec.data[0], rvec.data[1], rvec.data[2]])
    var o = mx(obj.rows, 2)
    for i in range(obj.rows):
        var x = rm.at(0, 0) * obj.at(i, 0) + rm.at(0, 1) * obj.at(i, 1) + rm.at(0, 2) * obj.at(i, 2) + tvec.data[0]
        var y = rm.at(1, 0) * obj.at(i, 0) + rm.at(1, 1) * obj.at(i, 1) + rm.at(1, 2) * obj.at(i, 2) + tvec.data[1]
        var z = rm.at(2, 0) * obj.at(i, 0) + rm.at(2, 1) * obj.at(i, 1) + rm.at(2, 2) * obj.at(i, 2) + tvec.data[2]
        z = z if z != 0 else 1.0
        var xy = fisheye_distort(x / z, y / z, d) if fisheye else distort(x / z, y / z, d)
        o.set(i, 0, 0, k.at(0, 0) * xy[0] + k.at(0, 1) * xy[1] + k.at(0, 2))
        o.set(i, 1, 0, k.at(1, 1) * xy[1] + k.at(1, 2))
    return o^


def undistort_points(pts: Mx, k: Mx, d: Mx, rr: Mx, p: Mx, fisheye: Bool) -> Mx:
    """Pixel to normalized (or P-projected) coordinates. Pinhole: five fixed-point iterations like cv2's default;
    fisheye: Newton on theta (10 iterations, 1e-8)."""
    var o = mx(pts.rows, 2)
    var fx = k.at(0, 0)
    var fy = k.at(1, 1)
    for i in range(pts.rows):
        var u = pts.at(i, 0)
        var v = pts.at(i, 1)
        var y0 = (v - k.at(1, 2)) / fy
        var x0 = (u - k.at(0, 2) - k.at(0, 1) * y0) / fx
        var x = x0
        var y = y0
        if fisheye:
            var td = min(max(sqrt(x0 * x0 + y0 * y0), -1.5707963267948966), 1.5707963267948966)
            var th = td
            var scale = 0.0
            var converged = False
            if abs(td) > 1e-8:
                for _ in range(10):
                    var t2 = th * th
                    var t4 = t2 * t2
                    var t6 = t4 * t2
                    var t8 = t6 * t2
                    var fix = (th * (1 + dist_at(d, 0) * t2 + dist_at(d, 1) * t4 + dist_at(d, 2) * t6 + dist_at(d, 3) * t8) - td) / (1 + 3 * dist_at(d, 0) * t2 + 5 * dist_at(d, 1) * t4 + 7 * dist_at(d, 2) * t6 + 9 * dist_at(d, 3) * t8)
                    th -= fix
                    if abs(fix) < 1e-8:
                        converged = True
                        break
                scale = tan(th) / td
            else:
                converged = True
            if not converged or (td > 0 and th < 0):
                o.set(i, 0, 0, -1e6)
                o.set(i, 1, 0, -1e6)
                continue
            x = x0 * scale
            y = y0 * scale
        else:
            for _ in range(5):
                var r2 = x * x + y * y
                var icd = (1 + ((dist_at(d, 7) * r2 + dist_at(d, 6)) * r2 + dist_at(d, 5)) * r2) / (1 + ((dist_at(d, 4) * r2 + dist_at(d, 1)) * r2 + dist_at(d, 0)) * r2)
                if icd < 0:
                    x = x0
                    y = y0
                    break
                var dx = 2 * dist_at(d, 2) * x * y + dist_at(d, 3) * (r2 + 2 * x * x) + dist_at(d, 8) * r2 + dist_at(d, 9) * r2 * r2
                var dy = dist_at(d, 2) * (r2 + 2 * y * y) + 2 * dist_at(d, 3) * x * y + dist_at(d, 10) * r2 + dist_at(d, 11) * r2 * r2
                x = (x0 - dx) * icd
                y = (y0 - dy) * icd
        var xx = rr.at(0, 0) * x + rr.at(0, 1) * y + rr.at(0, 2)
        var yy = rr.at(1, 0) * x + rr.at(1, 1) * y + rr.at(1, 2)
        var ww = rr.at(2, 0) * x + rr.at(2, 1) * y + rr.at(2, 2)
        ww = 1.0 / ww if ww != 0 else 1.0
        x = xx * ww
        y = yy * ww
        if p.rows > 0:
            o.set(i, 0, 0, p.at(0, 0) * x + p.at(0, 1) * y + p.at(0, 2))
            o.set(i, 1, 0, p.at(1, 1) * y + p.at(1, 2))
        else:
            o.set(i, 0, 0, x)
            o.set(i, 1, 0, y)
    return o^


def init_undistort_rectify_map(k: Mx, d: Mx, rr: Mx, p: Mx, w: Int, h: Int, fisheye: Bool) -> Tuple[Mat[DType.float32], Mat[DType.float32]]:
    """cv2.initUndistortRectifyMap: for each destination pixel the source position, via R^-1 and the distortion."""
    var mapx = Mat[DType.float32](h, w, 1)
    var mapy = Mat[DType.float32](h, w, 1)
    var pn = mx(3, 3)
    for i in range(3):
        for j in range(3):
            pn.set(i, j, 0, p.at(i, j))
    var fi = inv(pn)
    var rt = inv(rr)
    var pmx = mapx.ptr()
    var pmy = mapy.ptr()

    def row(v: Int) {imm}:
        for u in range(w):
            var x = fi.at(0, 0) * Float64(u) + fi.at(0, 1) * Float64(v) + fi.at(0, 2)
            var y = fi.at(1, 0) * Float64(u) + fi.at(1, 1) * Float64(v) + fi.at(1, 2)
            var z = fi.at(2, 0) * Float64(u) + fi.at(2, 1) * Float64(v) + fi.at(2, 2)
            var X = rt.at(0, 0) * x + rt.at(0, 1) * y + rt.at(0, 2) * z
            var Y = rt.at(1, 0) * x + rt.at(1, 1) * y + rt.at(1, 2) * z
            var W = rt.at(2, 0) * x + rt.at(2, 1) * y + rt.at(2, 2) * z
            W = 1.0 / W if W != 0 else 1.0
            var xy = fisheye_distort(X * W, Y * W, d) if fisheye else distort(X * W, Y * W, d)
            pmx[unsafe_offset=v * w + u] = Float32(k.at(0, 0) * xy[0] + k.at(0, 1) * xy[1] + k.at(0, 2))
            pmy[unsafe_offset=v * w + u] = Float32(k.at(1, 1) * xy[1] + k.at(1, 2))

    parallelize(row, h)
    _ = (fi.rows, rt.rows)
    return (mapx^, mapy^)


def run(mut a: Args) raises -> Bool:
    if a.op == "Rodrigues":
        var m = load[F64](a.ins[0])
        if m.size() == 3:
            save(rodrigues_vec([m.data[0], m.data[1], m.data[2]]), a.out)
        else:
            var v = rodrigues_vec_from(m)
            save(mx_from(v, 3, 1), a.out)
    elif a.op == "projectPoints" or a.op == "fisheye_projectPoints":
        var obj = load[F64](a.ins[0])
        var o = mx(0, 0)
        var rv = load[F64](a.ins[1])
        var tv = load[F64](a.ins[2])
        var k = load[F64](a.ins[3])
        var d = load[F64](a.ins[4])
        while a.again():
            o = project_points(obj, rv, tv, k, d, a.op == "fisheye_projectPoints")
        save(o, a.out)
    elif a.op == "undistortPoints" or a.op == "fisheye_undistortPoints":
        var pts = load[F64](a.ins[0])
        var k = load[F64](a.ins[1])
        var d = load[F64](a.ins[2])
        var rr = load[F64](a.ins[3]) if len(a.ins) > 3 else ident(3)
        var p = load[F64](a.ins[4]) if len(a.ins) > 4 else mx(0, 0)
        var o = mx(0, 0)
        while a.again():
            o = undistort_points(pts, k, d, rr, p, a.op == "fisheye_undistortPoints")
        save(o, a.out)
    elif a.op == "initUndistortRectifyMap" or a.op == "fisheye_initUndistortRectifyMap":
        var k = load[F64](a.ins[0])
        var d = load[F64](a.ins[1])
        var rr = load[F64](a.ins[2])
        var p = load[F64](a.ins[3])
        var o = (Mat[DType.float32](0, 0), Mat[DType.float32](0, 0))
        while a.again():
            o = init_undistort_rectify_map(k, d, rr, p, a.i("w", 640), a.i("h", 480), a.op == "fisheye_initUndistortRectifyMap")
        save(o[0], a.out)
        save(o[1], a.out + ".1")
    else:
        return False
    return True


def rodrigues_vec_from(m: Mx) -> List[Float64]:
    return rodrigues_mat(m)
