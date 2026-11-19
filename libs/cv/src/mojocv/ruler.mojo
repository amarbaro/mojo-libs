# ruler: scale from a tape measure lying in the frame, and the size of an object mask in that scale.
# tape_scale finds the yellow tape band (horizontal or vertical), takes the tick profile along each of its two edges,
# and tells the metric edge from the inch edge by its autocorrelation: a cm edge repeats at 5 and 10 times its finest
# period (5 mm, 1 cm), an inch edge at 8 and 16 times (1/2 in, 1 in). The cm period is refined on the 5 cm lag with a
# parabola through the peak, so one pixel of error spreads over five centimetres.
# object_box: bounding box of the largest 8-connected region of a mask, in px.
from std.math import log
from mojocv.mat import Mat, load, save
from mojocv.core import Args
from mojocv.imgproc import components

comptime F64 = DType.float64


def _yellow(r: Int, g: Int, b: Int) -> Bool:
    return r > 140 and g > 110 and b * 10 < g * 6 and r - b > 70


def _acorr(v: List[Float64], lag: Int) -> Float64:
    var n = len(v) - lag
    if n < 8:
        return 0.0
    var s = 0.0
    var e = 0.0
    for i in range(n):
        s += v[i] * v[i + lag]
        e += v[i] * v[i]
    return s / e if e > 0.0 else 0.0


def _peak(v: List[Float64], lo: Int, hi: Int) -> Float64:
    """Lag of the highest autocorrelation in [lo, hi], refined by a parabola through its neighbours."""
    var best = lo
    var bv = -2.0
    for l in range(lo, hi + 1):
        var a = _acorr(v, l)
        if a > bv:
            bv = a
            best = l
    var am = _acorr(v, best - 1)
    var ap = _acorr(v, best + 1)
    var d = am - 2.0 * bv + ap
    return Float64(best) + (0.5 * (am - ap) / d if d < 0.0 else 0.0)


def _first_peak(v: List[Float64], lo: Int, hi: Int) -> Float64:
    """Smallest lag in [lo, hi] that is a local maximum within 0.8 of the highest one (the fundamental, not a
    multiple), refined like _peak."""
    var a = List[Float64](length=hi + 2, fill=0.0)
    var top = -2.0
    for l in range(lo - 1, hi + 2):
        a[l] = _acorr(v, l)
    for l in range(lo, hi + 1):
        top = max(top, a[l])
    for l in range(lo, hi + 1):
        if a[l] >= a[l - 1] and a[l] >= a[l + 1] and a[l] >= 0.8 * top:
            return _peak(v, l, l)
    return _peak(v, lo, hi)


def _profile(src: Mat[DType.uint8], vert: Bool, a0: Int, a1: Int, s0: Int, s1: Int) -> List[Float64]:
    """Darkness along the tape (a0..a1) averaged over the strip s0..s1 across it, minus a 31-sample running mean."""
    var n = a1 - a0 + 1
    var p = List[Float64](length=n, fill=0.0)
    for i in range(n):
        var s = 0.0
        for j in range(s0, s1 + 1):
            var y = a0 + i if vert else j
            var x = j if vert else a0 + i
            var k = (y * src.cols + x) * 3
            s += 765.0 - Float64(Int(src.data[k]) + Int(src.data[k + 1]) + Int(src.data[k + 2]))
        p[i] = s / Float64(s1 - s0 + 1)
    var o = List[Float64](length=n, fill=0.0)
    for i in range(n):
        var lo = max(0, i - 15)
        var hi = min(n - 1, i + 15)
        var m = 0.0
        for j in range(lo, hi + 1):
            m += p[j]
        o[i] = p[i] - m / Float64(hi - lo + 1)
    return o^


def tape_scale(src: Mat[DType.uint8], hint: Float64 = 0.0) raises -> Mat[F64]:
    """1 x 7: px per cm, tape band across (lo, hi), along (lo, hi), vertical (0/1), metric-edge margin (cm score minus
    inch score; <= 0 means the edges were not told apart). Needs a 3-channel RGB image."""
    if src.ch != 3:
        raise Error("tapeScale needs a 3-channel RGB image, got " + String(src.ch) + " channels")
    var rc = List[Int](length=src.rows, fill=0)
    var cc = List[Int](length=src.cols, fill=0)
    for y in range(src.rows):
        for x in range(src.cols):
            var k = (y * src.cols + x) * 3
            if _yellow(Int(src.data[k]), Int(src.data[k + 1]), Int(src.data[k + 2])):
                rc[y] += 1
                cc[x] += 1
    var rmax = 0
    var cmax = 0
    for v in rc:
        rmax = max(rmax, v)
    for v in cc:
        cmax = max(cmax, v)
    var vert = cmax > rmax
    var across = cc.copy() if vert else rc.copy()
    var top = cmax if vert else rmax
    if top < 50:
        raise Error("tapeScale: no yellow tape band found")
    # band = the run of rows (columns) around the peak holding at least half the peak count
    var pk = 0
    for i in range(len(across)):
        if across[i] == top:
            pk = i
            break
    var b0 = pk
    var b1 = pk
    while b0 > 0 and across[b0 - 1] * 2 >= top:
        b0 -= 1
    while b1 < len(across) - 1 and across[b1 + 1] * 2 >= top:
        b1 += 1
    # extent along the tape: positions where most of the band is yellow
    var nalong = src.rows if vert else src.cols
    var a0 = -1
    var a1 = -1
    for i in range(nalong):
        var c = 0
        for j in range(b0, b1 + 1):
            var y = i if vert else j
            var x = j if vert else i
            var k = (y * src.cols + x) * 3
            if _yellow(Int(src.data[k]), Int(src.data[k + 1]), Int(src.data[k + 2])):
                c += 1
        if c * 5 >= (b1 - b0 + 1) * 3:
            if a0 < 0:
                a0 = i
            a1 = i
    if a1 - a0 < 200:
        raise Error("tapeScale: tape shorter than 200 px")
    # main tick period per edge, searched from 5 mm to 1 inch for a 19-25 mm wide blade
    var w = b1 - b0 + 1
    var d0 = Int(0.20 * Float64(w))
    var d1 = max(d0 + 1, Int(0.26 * Float64(w)))
    var lo = max(3, Int(Float64(w) / 5.5))
    var hi = Int(Float64(w) / 0.7) + 1
    var m = List[Float64](length=2, fill=0.0)
    var vs = List[List[Float64]]()
    for e in range(2):
        var s0 = b0 + d0 if e == 0 else b1 - d1
        var s1 = b0 + d1 if e == 0 else b1 - d0
        vs.append(_profile(src, vert, a0, a1, s0, s1))
        m[e] = _first_peak(vs[e], lo, hi)
    # hypothesis "edge e is metric": its own autocorrelation at its period plus the other edge's at 2.54 x that
    # (1 in over 1 cm, or 1/2 in over 5 mm: the ratio holds for both)
    var sc = List[Float64](length=2, fill=-9.0)
    for e in range(2):
        sc[e] = _acorr(vs[e], Int(m[e] + 0.5)) + _acorr(vs[1 - e], Int(2.54 * m[e] + 0.5))
    var e = 0 if sc[0] >= sc[1] else 1
    # 5 mm or 1 cm: in a deeper strip only the cm ticks reach, so alternate lattice ticks differ in darkness
    var p = m[e]
    var ph = 0
    var phv = -1e18
    for o in range(Int(p) + 1):
        var s = 0.0
        var x = Float64(o)
        while Int(x) < len(vs[e]):
            s += vs[e][Int(x)]
            x += p
        if s > phv:
            phv = s
            ph = o
    var g0 = Int(0.34 * Float64(w))
    var g1 = max(g0 + 1, Int(0.40 * Float64(w)))
    var deep = _profile(src, vert, a0, a1, b0 + g0 if e == 0 else b1 - g1, b0 + g1 if e == 0 else b1 - g0)
    var par = List[Float64](length=2, fill=0.0)
    var x = Float64(ph)
    var i = 0
    while Int(x) < len(deep):
        par[i % 2] += deep[Int(x)]
        x += p
        i += 1
    var hi2 = max(par[0], par[1])
    var lo2 = min(par[0], par[1])
    var ppcm = 2.0 * p if hi2 > 0.0 and lo2 < 0.5 * hi2 else p
    # a caller's rough scale (another shot of the same setup) overrides the parity guess: p or 2p, nearest in log.
    # Parity alone was right on 3 of 5 real phone photos (digits in the deep strip fake a long/short pattern).
    if hint > 0.0:
        ppcm = p if abs(log(p / hint)) < abs(log(2.0 * p / hint)) else 2.0 * p
    if 5.0 * ppcm < Float64(a1 - a0) / 2.0:
        ppcm = _peak(vs[e], Int(4.85 * ppcm), Int(5.15 * ppcm) + 1) / 5.0
    var bestm = sc[e] - sc[1 - e]
    var o = Mat[F64](1, 7, 1)
    o.data[0] = ppcm
    o.data[1] = Float64(b0)
    o.data[2] = Float64(b1)
    o.data[3] = Float64(a0)
    o.data[4] = Float64(a1)
    o.data[5] = 1.0 if vert else 0.0
    o.data[6] = bestm
    return o^


def object_box(m: Mat[DType.uint8], t: Int) raises -> Mat[F64]:
    """1 x 5: x, y, width, height, area (px) of the largest 8-connected region of pixels >= t."""
    if m.ch != 1:
        raise Error("objectBox needs a 1-channel mask, got " + String(m.ch) + " channels")
    var b = Mat[DType.uint8](m.rows, m.cols, 1)
    for i in range(len(m.data)):
        b.data[i] = 255 if Int(m.data[i]) >= t else 0
    var r = components(b, 8)
    var st = Mat[DType.int32](copy=r[1])
    var best = 0
    for k in range(1, st.rows):
        if best == 0 or st.data[k * 5 + 4] > st.data[best * 5 + 4]:
            best = k
    if best == 0:
        raise Error("objectBox: mask is empty at threshold " + String(t))
    var o = Mat[F64](1, 5, 1)
    for j in range(5):
        o.data[j] = Float64(st.data[best * 5 + j])
    return o^


def run(mut a: Args) raises -> Bool:
    if not (a.op in ["tapeScale", "objectBox"]):
        return False
    var m = load[DType.uint8](a.ins[0])
    var o = Mat[F64](0, 0)
    while a.again():
        o = tape_scale(m, a.f("hint", 0.0)) if a.op == "tapeScale" else object_box(m, a.i("t", 128))
    save(o, a.out)
    return True
