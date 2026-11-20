# regions: connected-region measures built on imgproc.components.
# hysteresis: keep the connected regions of (src > lo) that reach above hi and cover at least min_area pixels (the seeded
# threshold of morphological reconstruction, as used to drop isolated weak blobs from a probability map).
# clip_region: the largest connected region of clipped pixels, because Adobe refuses a blown void (one big region), which the
# share of clipped pixels does not tell from the same pixels scattered as sparkle.
from mojocv.mat import Mat, load, save
from mojocv.core import Args
from mojocv.imgproc import components

comptime F64 = DType.float64


def hysteresis(src: Mat[DType.uint8], lo: Int, hi: Int, min_area: Int, conn: Int) raises -> Mat[DType.uint8]:
    """uint8 mask, 255 inside the kept regions. Needs one channel and 0 <= lo < hi <= 255."""
    if src.ch != 1:
        raise Error("hysteresis needs a 1-channel image, got " + String(src.ch) + " channels")
    if lo < 0 or hi > 255 or lo >= hi:
        raise Error("hysteresis: need 0 <= lo < hi <= 255, got " + String(lo) + ", " + String(hi))
    if conn != 4 and conn != 8:
        raise Error("hysteresis: connectivity must be 4 or 8, got " + String(conn))
    var fg = Mat[DType.uint8](src.rows, src.cols, 1)
    for i in range(len(src.data)):
        fg.data[i] = 255 if Int(src.data[i]) > lo else 0
    var r = components(fg, conn)
    var st = Mat[DType.int32](copy=r[1])
    var n = st.rows
    var keep = List[Bool](length=n, fill=False)
    for k in range(1, n):
        keep[k] = Int(st.data[k * 5 + 4]) >= min_area
    var seeded = List[Bool](length=n, fill=False)
    for i in range(len(src.data)):
        if Int(src.data[i]) > hi:
            seeded[Int(r[0].data[i])] = True
    var o = Mat[DType.uint8](src.rows, src.cols, 1)
    for i in range(len(src.data)):
        var l = Int(r[0].data[i])
        if l > 0 and keep[l] and seeded[l]:
            o.data[i] = 255
    return o^


def _largest(g: Mat[DType.uint8], high: Bool, t: Int) raises -> SIMD[DType.float64, 4]:
    """(area share, box width share, box height share, region count) of the largest 8-connected region of pixels >= t (high)
    or <= t (low); zeros when none."""
    var m = Mat[DType.uint8](g.rows, g.cols, 1)
    for i in range(len(g.data)):
        var v = Int(g.data[i])
        m.data[i] = 255 if (v >= t if high else v <= t) else 0
    var r = components(m, 8)
    var st = Mat[DType.int32](copy=r[1])
    var n = st.rows
    var best = 0
    for k in range(1, n):
        if best == 0 or st.data[k * 5 + 4] > st.data[best * 5 + 4]:
            best = k
    if best == 0:
        return SIMD[DType.float64, 4](0.0)
    return SIMD[DType.float64, 4](
        Float64(st.data[best * 5 + 4]) / Float64(g.rows * g.cols),
        Float64(st.data[best * 5 + 2]) / Float64(g.cols),
        Float64(st.data[best * 5 + 3]) / Float64(g.rows),
        Float64(n - 1),
    )


def clip_region(g: Mat[DType.uint8], lo: Int, hi: Int) raises -> Mat[F64]:
    """1 x 8: for pixels >= hi then pixels <= lo: largest region's area share, its box width and height share, region count."""
    if g.ch != 1:
        raise Error("clipRegion needs a 1-channel grey image, got " + String(g.ch) + " channels")
    if lo < 0 or hi > 255 or lo >= hi:
        raise Error("clipRegion: need 0 <= lo < hi <= 255, got " + String(lo) + ", " + String(hi))
    var o = Mat[F64](1, 8, 1)
    var a = _largest(g, True, hi)
    var b = _largest(g, False, lo)
    for k in range(4):
        o.data[k] = a[k]
        o.data[4 + k] = b[k]
    return o^


def run(mut a: Args) raises -> Bool:
    if a.op != "hysteresis" and a.op != "clipRegion":
        return False
    var m = load[DType.uint8](a.ins[0])
    if a.op == "hysteresis":
        var o = Mat[DType.uint8](0, 0)
        while a.again():
            o = hysteresis(m, a.i("lo", 100), a.i("hi", 200), a.i("min_area", 1), a.i("connectivity", 8))
        save(o, a.out)
    else:
        var o = Mat[F64](0, 0)
        while a.again():
            o = clip_region(m, a.i("lo", 3), a.i("hi", 252))
        save(o, a.out)
    return True
