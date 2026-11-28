# texdefect: three signals for "textured only in part" on a rendered object picture (the ortho view sheet of a 3D asset):
#   blank   share of the object that is near-uniform light grey or white once shading is divided out,
#   seam    length of straight, high-contrast boundaries between a textured and a blank region inside the object,
#   stretch how strongly the fine texture is stretched along one axis (structure-tensor anisotropy, one direction).
# They run on the picture visualcheck already shrunk (long edge near 384) with its object mask, so a flat primitive and a
# half-textured model with the same silhouette differ only here. All three are measured on `core`: the mask eroded by 4 px, so
# the silhouette edge never counts as a seam or as texture. The shading is divided out as a relative number: local std over
# local mean of linear luma, so a white face in shade and one in light read alike.
from std.math import sqrt, atan2, cos, sin
from mojocv.mat import Mat
from mojocv.imgproc import morph

comptime U8 = DType.uint8
comptime PI = 3.141592653589793
comptime NTH = 24  # Hough angle bins over 180 degrees
comptime NRHO = 420  # rho bins of 3 px, offset NRHO / 2
comptime SEAM_D = 6  # px each side of an edge where texture and blank are sampled
comptime SEAM_MIN = 24  # votes (px) a line needs to count as a straight boundary


def _box(a: List[Float64], R: Int, C: Int, k: Int) -> List[Float64]:
    """k x k mean (at the borders: the part of the window inside the picture) through an integral image."""
    var r = k // 2
    var W = C + 1
    var s = List[Float64](length=(R + 1) * W, fill=0.0)
    for y in range(R):
        var row = 0.0
        for x in range(C):
            row += a[y * C + x]
            s[(y + 1) * W + x + 1] = s[y * W + x + 1] + row
    var o = List[Float64](length=R * C, fill=0.0)
    for y in range(R):
        var y0 = max(0, y - r)
        var y1 = min(R, y + r + 1)
        for x in range(C):
            var x0 = max(0, x - r)
            var x1 = min(C, x + r + 1)
            var t = s[y1 * W + x1] - s[y0 * W + x1] - s[y1 * W + x0] + s[y0 * W + x0]
            o[y * C + x] = t / Float64((y1 - y0) * (x1 - x0))
    return o^


def _sq(a: List[Float64]) -> List[Float64]:
    var o = List[Float64](length=len(a), fill=0.0)
    for i in range(len(a)):
        o[i] = a[i] * a[i]
    return o^


def defects(bgr: Mat[U8], lum: List[Int16], mask: Mat[U8], inner: Mat[U8]) raises -> List[Float64]:
    """[blank, seam, stretch]. `lum` is the gamma-lifted luma (x^0.45, 0..255) of `bgr`, `inner` the mask eroded by 2 px."""
    var out = List[Float64](length=3, fill=0.0)
    var R = bgr.rows
    var C = bgr.cols
    var N = R * C
    var core = morph[True, U8](inner, 0, 5, 1)
    var cp = core.ptr()
    var mp = mask.ptr()
    var p = bgr.ptr()
    var n = 0
    for i in range(N):
        if cp[i] != 0:
            n += 1
    if n < 64:
        return out^
    var fnn = Float64(n)
    var lift = List[Float64](length=N, fill=0.0)
    var lin = List[Float64](length=N, fill=0.0)
    var lh = List[Int](length=256, fill=0)
    for i in range(N):
        var v = Float64(lum[i])
        lift[i] = v
        lin[i] = (v / 255.0) ** (1.0 / 0.45) + 1e-4
        if cp[i] != 0:
            lh[Int(lum[i])] += 1
    # blank: low relative variation (shading divided out), low saturation, light against the object's own brightest 5 %
    var acc = 0
    var v95 = 255
    for v in range(256):
        acc += lh[v]
        if Float64(acc) >= 0.95 * fnn:
            v95 = v
            break
    var p95 = (Float64(v95) / 255.0) ** (1.0 / 0.45) + 1e-4
    var m5 = _box(lin, R, C, 5)
    var q5 = _box(_sq(lin), R, C, 5)
    var nb = 0
    for i in range(N):
        if cp[i] == 0:
            continue
        var s5 = sqrt(max(0.0, q5[i] - m5[i] * m5[i]))
        var mx = max(Int(p[i * 3]), max(Int(p[i * 3 + 1]), Int(p[i * 3 + 2])))
        var mn = min(Int(p[i * 3]), min(Int(p[i * 3 + 1]), Int(p[i * 3 + 2])))
        var sat = Float64(mx - mn) / Float64(max(mx, 1))
        if s5 / m5[i] < 0.05 and sat < 0.12 and m5[i] / p95 > 0.3:
            nb += 1
    out[0] = Float64(nb) / fnn
    # seam: edge pixels with texture on one side and blank on the other, then straight lines by a Hough vote on the gradient angle
    var l5 = _box(lift, R, C, 5)
    var d5 = _box(_sq(lift), R, C, 5)
    var sd = List[Float64](length=N, fill=0.0)
    for i in range(N):
        sd[i] = sqrt(max(0.0, d5[i] - l5[i] * l5[i]))
    var sm = _box(lift, R, C, 3)
    var gx = List[Float64](length=N, fill=0.0)
    var gy = List[Float64](length=N, fill=0.0)
    var gm = List[Float64](length=N, fill=0.0)
    for y in range(1, R - 1):
        for x in range(1, C - 1):
            var i = y * C + x
            var a = sm[i - C - 1]
            var b = sm[i - C]
            var c = sm[i - C + 1]
            var d = sm[i - 1]
            var f = sm[i + 1]
            var g = sm[i + C - 1]
            var h = sm[i + C]
            var j = sm[i + C + 1]
            gx[i] = ((c + 2.0 * f + j) - (a + 2.0 * d + g)) / 8.0
            gy[i] = ((g + 2.0 * h + j) - (a + 2.0 * b + c)) / 8.0
            gm[i] = sqrt(gx[i] * gx[i] + gy[i] * gy[i])
    var hv = List[Int](length=NTH * NRHO, fill=0)
    for y in range(R):
        for x in range(C):
            var i = y * C + x
            if cp[i] == 0 or gm[i] < 8.0:
                continue
            var ux = gx[i] / gm[i]
            var uy = gy[i] / gm[i]
            var xa = min(C - 1, max(0, Int(round(Float64(x) + Float64(SEAM_D) * ux))))
            var ya = min(R - 1, max(0, Int(round(Float64(y) + Float64(SEAM_D) * uy))))
            var xb = min(C - 1, max(0, Int(round(Float64(x) - Float64(SEAM_D) * ux))))
            var yb = min(R - 1, max(0, Int(round(Float64(y) - Float64(SEAM_D) * uy))))
            if cp[ya * C + xa] == 0 or cp[yb * C + xb] == 0:
                continue
            var sa = sd[ya * C + xa]
            var sb = sd[yb * C + xb]
            if not ((sa >= 4.0 and sb <= 1.5) or (sb >= 4.0 and sa <= 1.5)):
                continue
            var th = atan2(uy, ux)
            if th < 0.0:
                th += PI
            if th >= PI:
                th -= PI
            var tb = min(NTH - 1, Int(th / PI * Float64(NTH)))
            var thc = (Float64(tb) + 0.5) * PI / Float64(NTH)
            var rho = Float64(x) * cos(thc) + Float64(y) * sin(thc)
            var rb = Int(round(rho / 3.0)) + NRHO // 2
            if rb >= 1 and rb < NRHO - 1:
                hv[tb * NRHO + rb] += 1
    var sv = List[Int](length=NTH * NRHO, fill=0)
    for t in range(NTH):
        for r in range(1, NRHO - 1):
            var s = 0
            for dt in range(-1, 2):
                var t2 = t + dt
                if t2 < 0 or t2 >= NTH:
                    continue
                for dr in range(-1, 2):
                    s += hv[t2 * NRHO + r + dr]
            sv[t * NRHO + r] = s
    var seam = 0
    for t in range(NTH):
        for r in range(1, NRHO - 1):
            var s = sv[t * NRHO + r]
            if s < SEAM_MIN:
                continue
            var top = True
            for dt in range(-1, 2):
                var t2 = t + dt
                if t2 < 0 or t2 >= NTH:
                    continue
                for dr in range(-1, 2):
                    if r + dr >= 1 and r + dr < NRHO - 1 and sv[t2 * NRHO + r + dr] > s:
                        top = False
            if top:
                seam += s
    out[1] = Float64(seam) / sqrt(fnn)
    # stretch: structure tensor of the shading-free texture, away from strong edges; one dominant, coherent direction scores high
    var lo = _box(lift, R, C, 9)
    var hp = List[Float64](length=N, fill=0.0)
    for i in range(N):
        hp[i] = lift[i] - lo[i]
    var hs = _box(hp, R, C, 3)
    var hx = List[Float64](length=N, fill=0.0)
    var hy = List[Float64](length=N, fill=0.0)
    var hxy = List[Float64](length=N, fill=0.0)
    for y in range(1, R - 1):
        for x in range(1, C - 1):
            var i = y * C + x
            hx[i] = (hs[i + 1] - hs[i - 1]) / 2.0
            hy[i] = (hs[i + C] - hs[i - C]) / 2.0
            hxy[i] = hx[i] * hy[i]
    var strong = Mat[U8](R, C, 1, True)
    var sp = strong.ptr()
    for i in range(N):
        if gm[i] >= 20.0 and mp[i] != 0:
            sp[i] = 255
    var near = morph[False, U8](strong, 0, 13, 1)
    var nr = near.ptr()
    var jxx = _box(_sq(hx), R, C, 9)
    var jyy = _box(_sq(hy), R, C, 9)
    var jxy = _box(hxy, R, C, 9)
    var nt = 0
    var sw = 0.0
    var zr = 0.0
    var zi = 0.0
    for i in range(N):
        if cp[i] == 0 or nr[i] != 0:
            continue
        var tr = jxx[i] + jyy[i]
        if tr <= 1.0:
            continue
        nt += 1
        var dx = jxx[i] - jyy[i]
        var coh = sqrt(dx * dx + 4.0 * jxy[i] * jxy[i]) / tr
        var th2 = atan2(2.0 * jxy[i], dx)  # twice the orientation
        sw += tr
        zr += coh * tr * cos(th2)
        zi += coh * tr * sin(th2)
    if Float64(nt) >= 0.02 * fnn and sw > 0.0:
        out[2] = sqrt(zr * zr + zi * zi) / sw
    return out^
