# stockcheck: no-reference numbers behind stock-site rejections (blur, noise, JPEG blocks, banding, clipped
# exposure, colour cast, fog bands) and the 64-bit hashes that find near-duplicates in a batch.
# Gradient measures use interior pixels only (no border rule to agree on). Every op takes uint8 and raises on a
# wrong channel count or an image too small to measure; a quantity with no defined value (a flat image has no
# gradient to compare) is NaN, never a plausible number.
from std.math import sqrt, ceil, cos, nan
from std.bit import pop_count
from mojocv.mat import Mat, load, save
from mojocv.core import Args, par_dyn
from mojocv.imgproc import cvt_color
from mojocv.regions import clip_region
from mojocv.jpegio import load_jpeg
from mojocv.jpegyuv import load_jpeg_yuv, Yuv
from mojocv.gpustock import StockGpu, GpuRes

comptime F64 = DType.float64
comptime PI = 3.141592653589793


def _grey(g: Mat[DType.uint8], name: String, minside: Int) raises:
    if g.ch != 1:
        raise Error(name + " needs a 1-channel grey image, got " + String(g.ch) + " channels")
    if g.rows < minside or g.cols < minside:
        raise Error(name + ": image " + String(g.cols) + "x" + String(g.rows) + " smaller than " + String(minside) + " px")


def sharpness(g: Mat[DType.uint8], tile: Int, thr: Float64) raises -> Mat[F64]:
    """1 x 3: variance of the 4-neighbour Laplacian, Tenengrad (mean Sobel gx^2 + gy^2), and the share of full
    tile x tile blocks of the Laplacian whose variance is below thr (blur patches in a sharp frame)."""
    _grey(g, "sharpness", 3)
    var R = g.rows
    var C = g.cols
    var ty = (R - 2) // tile
    var tx = (C - 2) // tile
    if tile < 2 or ty < 1 or tx < 1:
        raise Error("sharpness: no full " + String(tile) + " px tile in the interior")
    var p = g.ptr()
    var ts1 = List[Int64](length=ty * tx, fill=0)
    var ts2 = List[Int64](length=ty * tx, fill=0)
    var s1: Int64 = 0
    var s2: Int64 = 0
    var tg: Int64 = 0
    for y in range(1, R - 1):
        var r0 = p + (y - 1) * C
        var r1 = p + y * C
        var r2 = p + (y + 1) * C
        var tyi = (y - 1) // tile
        for x in range(1, C - 1):
            var l = Int64(r0[x]) + Int64(r2[x]) + Int64(r1[x - 1]) + Int64(r1[x + 1]) - 4 * Int64(r1[x])
            var gx = Int64(r0[x + 1]) + 2 * Int64(r1[x + 1]) + Int64(r2[x + 1]) - Int64(r0[x - 1]) - 2 * Int64(r1[x - 1]) - Int64(r2[x - 1])
            var gy = Int64(r2[x - 1]) + 2 * Int64(r2[x]) + Int64(r2[x + 1]) - Int64(r0[x - 1]) - 2 * Int64(r0[x]) - Int64(r0[x + 1])
            s1 += l
            s2 += l * l
            tg += gx * gx + gy * gy
            var txi = (x - 1) // tile
            if tyi < ty and txi < tx:
                ts1[tyi * tx + txi] += l
                ts2[tyi * tx + txi] += l * l
    var n = Float64((R - 2) * (C - 2))
    var mean = Float64(s1) / n
    var tn = Int64(tile * tile)
    var soft = 0
    for i in range(ty * tx):
        if Float64(tn * ts2[i] - ts1[i] * ts1[i]) / Float64(tn * tn) < thr:
            soft += 1
    var o = Mat[F64](1, 3, 1)
    o.data[0] = Float64(s2) / n - mean * mean
    o.data[1] = Float64(tg) / n
    o.data[2] = Float64(soft) / Float64(ty * tx)
    return o^


def noise_est(g: Mat[DType.uint8]) raises -> Mat[F64]:
    """1 x 2: Immerkaer's sigma (sqrt(pi/2) / (6 N) * sum |g * [1 -2 1; -2 4 -2; 1 -2 1]|, interior) and the mean
    absolute difference of horizontally and vertically adjacent pixels (static reads high, a photo 3 to 6)."""
    _grey(g, "noiseEst", 3)
    var R = g.rows
    var C = g.cols
    var p = g.ptr()
    var s: Int64 = 0
    for y in range(1, R - 1):
        var r0 = p + (y - 1) * C
        var r1 = p + y * C
        var r2 = p + (y + 1) * C
        for x in range(1, C - 1):
            var v = Int64(r0[x - 1]) - 2 * Int64(r0[x]) + Int64(r0[x + 1]) - 2 * Int64(r1[x - 1]) + 4 * Int64(r1[x]) - 2 * Int64(r1[x + 1]) + Int64(r2[x - 1]) - 2 * Int64(r2[x]) + Int64(r2[x + 1])
            s += v if v >= 0 else -v
    var d: Int64 = 0
    for y in range(R):
        for x in range(C):
            var c = Int64(p[y * C + x])
            if x + 1 < C:
                var e = Int64(p[y * C + x + 1]) - c
                d += e if e >= 0 else -e
            if y + 1 < R:
                var e = Int64(p[(y + 1) * C + x]) - c
                d += e if e >= 0 else -e
    var o = Mat[F64](1, 2, 1)
    o.data[0] = sqrt(PI / 2.0) * Float64(s) / (6.0 * Float64((R - 2) * (C - 2)))
    o.data[1] = Float64(d) / Float64(R * (C - 1) + (R - 1) * C)
    return o^


def blockiness(g: Mat[DType.uint8]) raises -> Mat[F64]:
    """1 x 5: mean |difference| across 8-pixel block edges and elsewhere, horizontal (Bh, Nh) then vertical (Bv, Nv),
    and (Bh + Bv) / (Nh + Nv): near 1 for a clean image, above 1 once JPEG block seams show. NaN for a flat image."""
    _grey(g, "blockiness", 16)
    var R = g.rows
    var C = g.cols
    var p = g.ptr()
    # horizontal: 16 lanes starting at a multiple of 16 keep lane % 8 == x % 8, so lanes 7 and 15 are block edges
    var hb: Int64 = 0
    var hn: Int64 = 0
    for y in range(R):
        var r = p + y * C
        var acc = SIMD[DType.uint32, 16](0)
        var x = 0
        while x + 17 <= C:
            var a = r.unsafe_load[width=16](x)
            var b = r.unsafe_load[width=16](x + 1)
            acc += (max(a, b) - min(a, b)).cast[DType.uint32]()
            x += 16
        var edge = Int64(acc[7]) + Int64(acc[15])
        hb += edge
        hn += Int64(acc.reduce_add()) - edge
        for xx in range(x, C - 1):
            var e = Int64(r[xx + 1]) - Int64(r[xx])
            if xx % 8 == 7:
                hb += e if e >= 0 else -e
            else:
                hn += e if e >= 0 else -e
    var vb: Int64 = 0
    var vn: Int64 = 0
    for y in range(R - 1):
        var r0 = p + y * C
        var r1 = p + (y + 1) * C
        var acc = SIMD[DType.uint32, 32](0)
        var x = 0
        while x + 32 <= C:
            var a = r0.unsafe_load[width=32](x)
            var b = r1.unsafe_load[width=32](x)
            acc += (max(a, b) - min(a, b)).cast[DType.uint32]()
            x += 32
        var s = Int64(acc.reduce_add())
        for xx in range(x, C):
            var e = Int64(r1[xx]) - Int64(r0[xx])
            s += e if e >= 0 else -e
        if y % 8 == 7:
            vb += s
        else:
            vn += s
    return _blk_out(hb, hn, vb, vn, R, C)


def _blk_out(hb: Int64, hn: Int64, vb: Int64, vn: Int64, R: Int, C: Int) -> Mat[F64]:
    """blockiness' 1 x 5 from its four sums (the GPU path brings the sums)."""
    var sums = SIMD[DType.int64, 4](0)
    var cnts = SIMD[DType.int64, 4](0)
    var nb = (C - 1) // 8  # horizontal positions per row with x % 8 == 7, x <= C - 2
    var mb = (R - 1) // 8
    sums[0] = hb
    sums[1] = hn
    sums[2] = vb
    sums[3] = vn
    cnts[0] = Int64(R * nb)
    cnts[1] = Int64(R * (C - 1 - nb))
    cnts[2] = Int64(mb * C)
    cnts[3] = Int64((R - 1 - mb) * C)
    var o = Mat[F64](1, 5, 1)
    for k in range(4):
        o.data[k] = Float64(sums[k]) / Float64(cnts[k])
    var den = o.data[1] + o.data[3]
    o.data[4] = (o.data[0] + o.data[2]) / den if den > 0 else nan[F64]()
    return o^


def clipping(g: Mat[DType.uint8], lo: Int, hi: Int) raises -> Mat[F64]:
    """1 x 6: share of pixels <= lo, share >= hi, 1st and 99th percentile (smallest v with cdf >= q), mean, std."""
    _grey(g, "clipping", 1)
    if lo < 0 or hi > 255 or lo >= hi:
        raise Error("clipping: need 0 <= lo < hi <= 255, got " + String(lo) + ", " + String(hi))
    var h = List[Int64](length=256, fill=0)
    for v in g.data:
        h[Int(v)] += 1
    var n = Float64(len(g.data))
    var a = 0
    var b = 0
    var s: Int64 = 0
    var s2: Int64 = 0
    for v in range(256):
        if v <= lo:
            a += Int(h[v])
        if v >= hi:
            b += Int(h[v])
        s += Int64(v) * h[v]
        s2 += Int64(v * v) * h[v]
    var o = Mat[F64](1, 6, 1)
    o.data[0] = Float64(a) / n
    o.data[1] = Float64(b) / n
    for qi in range(2):
        var k = Int(ceil((0.01 if qi == 0 else 0.99) * n))
        var c: Int64 = 0
        for v in range(256):
            c += h[v]
            if Int(c) >= k:
                o.data[2 + qi] = Float64(v)
                break
    var m = Float64(s) / n
    o.data[4] = m
    o.data[5] = sqrt(Float64(s2) / n - m * m)
    return o^


def color_cast(src: Mat[DType.uint8]) raises -> Mat[F64]:
    """1 x 5 from a BGR image: mean B, G, R, R - G, and B - (R + G) / 2 (gray-world: a neutral scene has both near
    0; a legitimately blue or green scene reads as a cast too, so this flags, the judge decides)."""
    if src.ch != 3:
        raise Error("colorCast needs a 3-channel BGR image, got " + String(src.ch) + " channels")
    var p = src.ptr()
    var n0 = src.rows * src.cols
    var s0: UInt64 = 0
    var s1: UInt64 = 0
    var s2: UInt64 = 0
    for i in range(n0):
        s0 += UInt64(p[i * 3])
        s1 += UInt64(p[i * 3 + 1])
        s2 += UInt64(p[i * 3 + 2])
    return _cast_out(s0, s1, s2, n0)


def _cast_out(s0: UInt64, s1: UInt64, s2: UInt64, n0: Int) -> Mat[F64]:
    """color_cast's 1 x 5 from the B, G, R sums over n0 pixels."""
    var n = Float64(n0)
    var o = Mat[F64](1, 5, 1)
    o.data[0] = Float64(s0) / n
    o.data[1] = Float64(s1) / n
    o.data[2] = Float64(s2) / n
    o.data[3] = o.data[2] - o.data[1]
    o.data[4] = o.data[0] - (o.data[2] + o.data[1]) / 2.0
    return o^


def banding(g: Mat[DType.uint8], tile: Int, max_std: Float64, min_range: Int) raises -> Mat[F64]:
    """1 x 4 over smooth tiles (range >= min_range, std <= max_std): share of tiles that are smooth, share of
    adjacent pixel pairs that are equal, share of unequal pairs that jump 2+ levels, smooth tile count.
    Banded gradients show long flat runs with big steps; a clean gradient has short runs of 1-level steps."""
    _grey(g, "banding", 2)
    var ty = g.rows // tile
    var tx = g.cols // tile
    if tile < 2 or ty < 1 or tx < 1:
        raise Error("banding: no full " + String(tile) + " px tile")
    var p = g.ptr()
    var C = g.cols
    var ns = 0
    var pairs = 0
    var eq = 0
    var neq = 0
    var jump = 0
    var tn = Int64(tile * tile)
    for by in range(ty):
        for bx in range(tx):
            var s: Int64 = 0
            var s2: Int64 = 0
            var lo = 255
            var hi = 0
            for y in range(tile):
                for x in range(tile):
                    var v = Int(p[(by * tile + y) * C + bx * tile + x])
                    s += Int64(v)
                    s2 += Int64(v * v)
                    lo = min(lo, v)
                    hi = max(hi, v)
            if hi - lo < min_range or Float64(tn * s2 - s * s) > max_std * max_std * Float64(tn * tn):
                continue
            ns += 1
            for y in range(tile):
                for x in range(tile):
                    var v = Int(p[(by * tile + y) * C + bx * tile + x])
                    for k in range(2):
                        if (k == 0 and x + 1 < tile) or (k == 1 and y + 1 < tile):
                            var w = Int(p[(by * tile + y + k) * C + bx * tile + x + 1 - k])
                            var d = abs(w - v)
                            pairs += 1
                            if d == 0:
                                eq += 1
                            else:
                                neq += 1
                                if d >= 2:
                                    jump += 1
    var o = Mat[F64](1, 4, 1)
    o.data[0] = Float64(ns) / Float64(ty * tx)
    o.data[1] = Float64(eq) / Float64(pairs) if pairs > 0 else nan[F64]()
    o.data[2] = Float64(jump) / Float64(neq) if neq > 0 else nan[F64]()
    o.data[3] = Float64(ns)
    return o^


def haze_band(g: Mat[DType.uint8]) raises -> Mat[F64]:
    """1 x 4: split into 4 column strips and 4 row strips; per strip the mean interior Sobel energy; per axis the
    weakest strip over the median of the four (a fog band is a strip far below 1) and which strip it is."""
    _grey(g, "hazeBand", 8)
    var R = g.rows
    var C = g.cols
    var p = g.ptr()
    var ce = List[Int64](length=4, fill=0)
    var cn = List[Int64](length=4, fill=0)
    var re = List[Int64](length=4, fill=0)
    var rn = List[Int64](length=4, fill=0)
    for y in range(1, R - 1):
        var r0 = p + (y - 1) * C
        var r1 = p + y * C
        var r2 = p + (y + 1) * C
        var ry = y * 4 // R
        for x in range(1, C - 1):
            var gx = Int64(r0[x + 1]) + 2 * Int64(r1[x + 1]) + Int64(r2[x + 1]) - Int64(r0[x - 1]) - 2 * Int64(r1[x - 1]) - Int64(r2[x - 1])
            var gy = Int64(r2[x - 1]) + 2 * Int64(r2[x]) + Int64(r2[x + 1]) - Int64(r0[x - 1]) - 2 * Int64(r0[x]) - Int64(r0[x + 1])
            var e = gx * gx + gy * gy
            var cx = x * 4 // C
            ce[cx] += e
            cn[cx] += 1
            re[ry] += e
            rn[ry] += 1
    var o = Mat[F64](1, 4, 1)
    for ax in range(2):
        var c = List[Float64](length=4, fill=0.0)
        for i in range(4):
            var num = ce[i] if ax == 0 else re[i]
            var den = cn[i] if ax == 0 else rn[i]
            if den == 0:
                raise Error("hazeBand: empty strip")
            c[i] = Float64(num) / Float64(den)
        var s = c.copy()
        for i in range(1, 4):
            var j = i
            while j > 0 and s[j - 1] > s[j]:
                var t = s[j]
                s[j] = s[j - 1]
                s[j - 1] = t
                j -= 1
        var med = (s[1] + s[2]) / 2.0
        var best = 0
        for i in range(1, 4):
            if c[i] < c[best]:
                best = i
        o.data[2 * ax] = c[best] / med if med > 0 else nan[F64]()
        o.data[2 * ax + 1] = Float64(best)
    return o^


def _box_means(g: Mat[DType.uint8], gh: Int, gw: Int) raises -> List[Float64]:
    """Mean of each cell of a gh x gw grid, cell (i, j) = rows [i R // gh, (i+1) R // gh), cols likewise."""
    if g.rows < gh or g.cols < gw:
        raise Error("hashes: image " + String(g.cols) + "x" + String(g.rows) + " smaller than the " + String(gw) + "x" + String(gh) + " grid")
    var p = g.ptr()
    var sums = List[Int64](length=gh * gw, fill=0)
    for i in range(gh):
        for j in range(gw):
            var s: Int64 = 0
            for y in range(i * g.rows // gh, (i + 1) * g.rows // gh):
                for x in range(j * g.cols // gw, (j + 1) * g.cols // gw):
                    s += Int64(p[y * g.cols + x])
            sums[i * gw + j] = s
    return _means(sums, 0, gh, gw, g.rows, g.cols)


def _means(sums: List[Int64], at: Int, gh: Int, gw: Int, R: Int, C: Int) -> List[Float64]:
    """The cell means of _box_means from the cell sums sums[at ..]."""
    var out = List[Float64](length=gh * gw, fill=0.0)
    for i in range(gh):
        var y0 = i * R // gh
        var y1 = (i + 1) * R // gh
        for j in range(gw):
            var x0 = j * C // gw
            var x1 = (j + 1) * C // gw
            out[i * gw + j] = Float64(sums[at + i * gw + j]) / Float64((y1 - y0) * (x1 - x0))
    return out^


def hashes(g: Mat[DType.uint8]) raises -> Mat[DType.uint8]:
    """2 x 64 bits. Row 0 dHash: 8 x 9 box means, bit = right neighbour brighter. Row 1 pHash: 32 x 32 box means,
    orthonormal DCT-II, the 63 lowest AC coefficients (rounded to 1e-6) above their median, bit 63 is 0."""
    _grey(g, "hashes", 1)
    return _hash_bits(_box_means(g, 8, 9), _box_means(g, 32, 32))


def _hash_bits(d: List[Float64], m: List[Float64]) -> Mat[DType.uint8]:
    """hashes' 2 x 64 bits from the 8 x 9 and 32 x 32 box means."""
    var o = Mat[DType.uint8](2, 64, 1)
    for i in range(8):
        for j in range(8):
            o.data[i * 8 + j] = 1 if d[i * 9 + j + 1] > d[i * 9 + j] else 0
    var t = List[Float64](length=8 * 32, fill=0.0)
    for k in range(8):
        var sc = sqrt(1.0 / 32.0) if k == 0 else sqrt(2.0 / 32.0)
        for n in range(32):
            t[k * 32 + n] = sc * cos(PI * Float64(2 * n + 1) * Float64(k) / 64.0)
    var rowdct = List[Float64](length=32 * 8, fill=0.0)  # [i][l]: DCT along the columns of row i
    for i in range(32):
        for l in range(8):
            var s = 0.0
            for j in range(32):
                s += t[l * 32 + j] * m[i * 32 + j]
            rowdct[i * 8 + l] = s
    var q = List[Float64](length=64, fill=0.0)
    for k in range(8):
        for l in range(8):
            var s = 0.0
            for i in range(32):
                s += t[k * 32 + i] * rowdct[i * 8 + l]
            q[k * 8 + l] = ceil(s * 1e6 - 0.5)
    var ac = List[Float64]()
    for i in range(1, 64):
        ac.append(q[i])
    for i in range(1, len(ac)):
        var j = i
        while j > 0 and ac[j - 1] > ac[j]:
            var tmp = ac[j]
            ac[j] = ac[j - 1]
            ac[j - 1] = tmp
            j -= 1
    var med = ac[31]
    for i in range(1, 64):
        o.data[64 + i - 1] = 1 if q[i] > med else 0
    return o^


def ham_pairs(bits: Mat[DType.uint8], thr: Int) raises -> Mat[DType.int32]:
    """M x 3 int32 rows (i, j, distance), i < j in order, for every pair of the N rows of 64 bits within thr."""
    if bits.cols != 64 or bits.ch != 1:
        raise Error("hamPairs needs N x 64 single-channel bits, got " + String(bits.cols) + " x " + String(bits.ch))
    var w = List[UInt64](length=bits.rows, fill=0)
    for i in range(bits.rows):
        for k in range(64):
            var b = bits.data[i * 64 + k]
            if b > 1:
                raise Error("hamPairs: bit value " + String(b) + " at row " + String(i))
            w[i] |= UInt64(b) << UInt64(k)
    var out = List[Int32]()
    for i in range(bits.rows):
        for j in range(i + 1, bits.rows):
            var d = Int(pop_count(w[i] ^ w[j]))
            if d <= thr:
                out.append(Int32(i))
                out.append(Int32(j))
                out.append(Int32(d))
    var o = Mat[DType.int32](len(out) // 3, 3, 1)
    for i in range(len(out)):
        o.data[i] = out[i]
    return o^


comptime NM = 37  # numbers per image from stock_metrics
comptime GPU_WIN = 24  # files per decode window of stockBatch gpu=1 (a 21 MP 4:2:0 JPEG holds 32 MB of planes)


def scale_factor(rows: Int, cols: Int, ascale: Int) -> Int:
    """Integer shrink that brings the long edge near `ascale` px: round(long / ascale), at least 1."""
    return max(1, (max(rows, cols) + ascale // 2) // ascale)


def box_down(g: Mat[DType.uint8], f: Int) raises -> Mat[DType.uint8]:
    """Shrink a grey image by the integer f: each output pixel is the rounded mean of an f x f block (the
    remainder rows and columns on the bottom and right are dropped)."""
    _grey(g, "boxDown", 1)
    if f < 1 or g.rows < f or g.cols < f:
        raise Error("boxDown: factor " + String(f) + " does not fit " + String(g.cols) + "x" + String(g.rows))
    var R = g.rows // f
    var C = g.cols // f
    var o = Mat[DType.uint8](R, C, 1, False)
    var p = g.ptr()
    var q = o.ptr()
    var half = (f * f) // 2
    for y in range(R):
        for x in range(C):
            var s = 0
            for dy in range(f):
                var r = p + (y * f + dy) * g.cols + x * f
                for dx in range(f):
                    s += Int(r[dx])
            q[y * C + x] = UInt8((s + half) // (f * f))
    return o^


def _analyse(src: Mat[DType.uint8], tile: Int, thr: Float64, lo: Int, hi: Int, bt: Int, bstd: Float64, brange: Int, ascale: Int) raises -> Tuple[Mat[F64], Mat[DType.uint8]]:
    """(1 x 37 numbers, 2 x 64 hash bits) of a BGR image, the grey image computed once (cv2's BGR2GRAY)."""
    if src.ch != 3:
        raise Error("stockMetrics needs a 3-channel BGR image, got " + String(src.ch) + " channels")
    var g = cvt_color(src, 0)
    var f = scale_factor(g.rows, g.cols, ascale)
    var ga = box_down(g, f) if f > 1 else Mat[DType.uint8](copy=g)  # sharpness, noise, banding, fog at one analysis scale
    var parts = List[Mat[F64]]()
    parts.append(sharpness(ga, tile, thr))
    parts.append(noise_est(ga))
    parts.append(blockiness(g))  # the 8 x 8 grid only exists at native size
    parts.append(clipping(ga, lo, hi))
    parts.append(color_cast(src))
    parts.append(banding(ga, bt, bstd, brange))
    parts.append(haze_band(ga))
    parts.append(clip_region(ga, lo, hi))
    var o = Mat[F64](1, NM, 1)
    var k = 0
    for i in range(len(parts)):
        for v in parts[i].data:
            o.data[k] = v
            k += 1
    return (o^, hashes(g))


def _gpu_fits(h: Int, w: Int, ascale: Int) -> Bool:
    """A picture the GPU path takes: every op of _analyse has room (the hash grids, blockiness' 16 px, the tiles at analysis scale)."""
    var f = scale_factor(h, w, ascale)
    return min(h, w) >= 64 and min(h // f, w // f) >= 64


def _analyse_gpu(r: GpuRes, h: Int, w: Int, tile: Int, thr: Float64, lo: Int, hi: Int, bt: Int, bstd: Float64, brange: Int) raises -> Tuple[Mat[F64], Mat[DType.uint8]]:
    """_analyse from what the card brought back: the analysis-scale grey and the sums of the full-size ops."""
    var hb: Int64 = 0
    var hn: Int64 = 0
    var vb: Int64 = 0
    var vn: Int64 = 0
    for y in range(h):
        hb += r.blk[3 * y]
        hn += r.blk[3 * y + 1]
        if y % 8 == 7:
            vb += r.blk[3 * y + 2]
        else:
            vn += r.blk[3 * y + 2]
    var parts = List[Mat[F64]]()
    parts.append(sharpness(r.ga, tile, thr))
    parts.append(noise_est(r.ga))
    parts.append(_blk_out(hb, hn, vb, vn, h, w))
    parts.append(clipping(r.ga, lo, hi))
    parts.append(_cast_out(UInt64(r.cast[0]), UInt64(r.cast[1]), UInt64(r.cast[2]), h * w))
    parts.append(banding(r.ga, bt, bstd, brange))
    parts.append(haze_band(r.ga))
    parts.append(clip_region(r.ga, lo, hi))
    var o = Mat[F64](1, NM, 1)
    var k = 0
    for i in range(len(parts)):
        for v in parts[i].data:
            o.data[k] = v
            k += 1
    return (o^, _hash_bits(_means(r.cells, 0, 8, 9, h, w), _means(r.cells, 72, 32, 32, h, w)))


def stock_metrics(src: Mat[DType.uint8], a: Args) raises -> Mat[F64]:
    """1 x 37 from a BGR image, in this order: sharpness(3) noiseEst(2) blockiness(5) clipping(6) colorCast(5)
    banding(4) hazeBand(4) clipRegion(8)."""
    var r = _analyse(src, a.i("tile", 32), a.f("thr", 10.0), a.i("lo", 3), a.i("hi", 252), a.i("btile", 16), a.f("bstd", 6.0), a.i("brange", 3), a.i("ascale", 1536))
    return Mat[F64](copy=r[0])


def _jn(v: Float64) -> String:
    return "null" if v != v else String(v)


def _hex(bits: List[UInt8], at: Int) -> String:
    var w: UInt64 = 0
    for k in range(64):
        w |= UInt64(bits[at + k]) << UInt64(k)
    var s = String()
    for i in range(16):
        var d = Int((w >> UInt64(60 - 4 * i)) & 15)
        s += String(chr(d + 48 if d < 10 else d + 87))
    return s^


def _esc(s: String) -> String:
    var o = String()
    for c in s.codepoints():
        if c == Codepoint.ord('"') or c == Codepoint.ord("\\"):
            o += "\\"
        o += String(c)
    return o^


def _load_ppm(path: String) raises -> Mat[DType.uint8]:
    """A binary P6 file with 8-bit RGB (what `vips autorot IN OUT.ppm` writes) as a BGR Mat."""
    var b = open(path, "r").read_bytes()
    if len(b) < 2 or b[0] != 80 or b[1] != 54:
        raise Error("mojocv: not a P6 file: " + path)
    var pos = 2
    var v = List[Int]()
    while len(v) < 3:
        while pos < len(b) and (b[pos] == 32 or b[pos] == 10 or b[pos] == 13 or b[pos] == 9):
            pos += 1
        if pos < len(b) and b[pos] == 35:  # a comment runs to the end of its line
            while pos < len(b) and b[pos] != 10:
                pos += 1
            continue
        var x = 0
        var nd = 0
        while pos < len(b) and b[pos] >= 48 and b[pos] <= 57 and nd < 9:
            x = x * 10 + Int(b[pos]) - 48
            pos += 1
            nd += 1
        if nd == 0:
            raise Error("mojocv: bad P6 header: " + path)
        v.append(x)
    pos += 1  # the one whitespace byte after maxval
    var w = v[0]
    var h = v[1]
    var left = len(b) - pos
    if v[2] != 255 or w < 1 or h < 1 or left < 0 or left % 3 != 0 or (left // 3) % w != 0 or (left // 3) // w != h:
        raise Error("mojocv: " + path + " is not an 8-bit " + String(w) + "x" + String(h) + " RGB P6 with " + String(left) + " data bytes")
    var m = Mat[DType.uint8](h, w, 3, False)
    var q = m.ptr()
    var s = b.unsafe_ptr() + pos
    for i in range(w * h):
        q[3 * i] = s[3 * i + 2]
        q[3 * i + 1] = s[3 * i + 1]
        q[3 * i + 2] = s[3 * i]
    _ = len(b)
    return m^


def _load_any(path: String) raises -> Mat[DType.uint8]:
    var low = path.lower()
    if low.endswith(".jpg") or low.endswith(".jpeg"):
        return load_jpeg(path)
    return _load_ppm(path) if path.endswith(".ppm") else load[DType.uint8](path)


def batch(mut a: Args) raises -> Bool:
    """stockBatch OUT.jsonl BATCH.tsv [k=v]: BATCH.tsv rows are `mcv path <TAB> original path <TAB> original bytes`.
    One JSON line per image (numbers, hashes, flags, near-duplicates in the batch), images analysed in parallel.
    A line with "error" set holds no numbers: the image could not be measured, which is not a pass."""
    var rows = open(a.ins[0], "r").read().split("\n")
    var paths = List[String]()
    var origs = List[String]()
    var sizes = List[Int]()
    for r in rows:
        var f = r.split("\t")
        if len(f) < 2:
            continue
        paths.append(String(f[0]))
        origs.append(String(f[1]))
        sizes.append(Int(atol(String(f[2]))) if len(f) > 2 else 0)
    var n = len(paths)
    var tile = a.i("tile", 32)
    var thr = a.f("thr", 10.0)
    var lo = a.i("lo", 3)
    var hi = a.i("hi", 252)
    var bt = a.i("btile", 16)
    var bs = a.f("bstd", 6.0)
    var br = a.i("brange", 3)
    var asc = a.i("ascale", 1536)
    var res = List[Float64](length=n * NM, fill=0.0)
    var dims = List[Int](length=n * 2, fill=0)
    var hb = List[UInt8](length=n * 128, fill=0)
    var ef = List[Int](length=n, fill=0)
    var rp = res.unsafe_ptr()
    var hp = hb.unsafe_ptr()
    var dp = dims.unsafe_ptr()
    var ep = ef.unsafe_ptr()
    # gpu=1: a JPEG the card takes is decoded to its planes here, finished on the GPU (gpustock.mojo), measured from what came
    # back; every other file takes the CPU path below in the same pass. Windows of GPU_WIN files bound the planes held in RAM.
    var sg: Optional[StockGpu] = None
    if a.i("gpu", 0) == 1:
        try:
            sg = StockGpu()
        except e:
            print("gpu: no device (" + String(e) + "), CPU path")
    var yv = List[Yuv]()
    var gr = List[GpuRes]()
    for _ in range(n if sg else 0):
        yv.append(Yuv())
        gr.append(GpuRes())
    var kind = List[Int](length=n, fill=0)  # 1: planes waiting for the GPU, 2: GPU results waiting for the CPU
    var yp = yv.unsafe_ptr()
    var gp = gr.unsafe_ptr()
    var kp = kind.unsafe_ptr()
    var usegpu = Bool(sg)

    def put(i: Int, r: Tuple[Mat[F64], Mat[DType.uint8]]) {imm}:
        for j in range(NM):
            rp[i * NM + j] = r[0].data[j]
        for j in range(128):
            hp[i * 128 + j] = r[1].data[j]

    var win = GPU_WIN if usegpu else max(n, 1)
    var s = 0
    while s < n:
        var e = min(n, s + win)
        var base = s

        def task(k: Int) {imm}:
            var i = base + k
            try:
                if usegpu:
                    var low = paths[i].lower()
                    if low.endswith(".jpg") or low.endswith(".jpeg"):
                        try:
                            var y = load_jpeg_yuv(paths[i])
                            if _gpu_fits(y.h, y.w, asc):
                                dp[2 * i] = y.w
                                dp[2 * i + 1] = y.h
                                yp[i] = y^
                                kp[i] = 1
                                return
                        except err:
                            if not String(err).startswith("jpeg-cpu"):
                                ep[i] = 1
                                return
                var src = _load_any(paths[i])
                dp[2 * i] = src.cols
                dp[2 * i + 1] = src.rows
                put(i, _analyse(src, tile, thr, lo, hi, bt, bs, br, asc))
            except:
                ep[i] = 1

        par_dyn(task, e - s)
        for i in range(s, e):
            if kind[i] == 1:
                try:
                    gr[i] = sg.value().analyse(yv[i], scale_factor(dims[2 * i + 1], dims[2 * i], asc), False)
                    kind[i] = 2
                except:
                    ef[i] = 1
                yv[i] = Yuv()

        def fin(k: Int) {imm}:
            var i = base + k
            if kp[i] != 2:
                return
            try:
                put(i, _analyse_gpu(gp[i], dp[2 * i + 1], dp[2 * i], tile, thr, lo, hi, bt, bs, br))
            except:
                ep[i] = 1
            gp[i] = GpuRes()

        if usegpu:
            par_dyn(fin, e - s)
        s = e
    _ = (len(res), len(hb), len(dims), len(ef), len(yv), len(gr), len(kind))
    var errs = List[String](length=n, fill=String())
    for i in range(n):  # the reason of a failed image, read again on this thread
        if ef[i] != 0:
            try:
                _ = _analyse(_load_any(paths[i]), tile, thr, lo, hi, bt, bs, br, asc)
                errs[i] = "analysis failed"
            except e:
                errs[i] = String(e)
    var minmp = a.f("minmp", 4.0)
    var out = open(a.out, "w")
    var sidecar = a.i("sidecar", 0)
    for i in range(n):
        var line = String('{"file":"', _esc(origs[i]), '"')
        if errs[i].byte_length() > 0:
            line += String(',"error":"', _esc(errs[i]), '"}')
        else:
            var m = rp + i * NM
            var w = dims[2 * i]
            var h = dims[2 * i + 1]
            var mp = Float64(w * h) / 1e6
            var fl = List[String]()
            if mp < minmp:
                fl.append("lowres")
            if m[0] < a.f("blurlap", 15.0):
                fl.append("blur")
            if m[3] > a.f("noisesig", 6.0):
                fl.append("noise")
            if m[9] > a.f("blk", 2.0):
                fl.append("blocks")
            if m[21] >= a.f("bandmin", 0.05) and m[22] > a.f("bandeq", 0.85) and m[23] > a.f("bandjump", 0.7):
                fl.append("banding")
            if m[11] > a.f("cliphi", 0.1):
                fl.append("clipHigh")
            if m[10] > a.f("cliplo", 0.5):
                fl.append("clipLow")
            if m[29] > a.f("voidhi", 0.08):
                fl.append("blownVoid")
            if abs(m[19]) > a.f("castrg", 35.0) or abs(m[20]) > a.f("castby", 60.0):
                fl.append("cast")
            if m[25] < a.f("flatstrip", 0.001) or m[27] < a.f("flatstrip", 0.001):
                fl.append("flatStrip")
            line += String(',"w":', w, ',"h":', h, ',"scale":', scale_factor(h, w, asc), ',"mp":', _jn(mp), ',"bytes":', sizes[i])
            line += String(',"sharp":{"lapvar":', _jn(m[0]), ',"tenengrad":', _jn(m[1]), ',"softTiles":', _jn(m[2]), "}")
            line += String(',"noise":{"sigma":', _jn(m[3]), ',"nbr":', _jn(m[4]), "}")
            line += String(',"blocks":', _jn(m[9]))
            line += String(',"clip":{"lo":', _jn(m[10]), ',"hi":', _jn(m[11]), ',"p01":', _jn(m[12]), ',"p99":', _jn(m[13]), "}")
            line += String(',"void":{"hi":', _jn(m[29]), ',"hiW":', _jn(m[30]), ',"hiH":', _jn(m[31]), ',"lo":', _jn(m[33]), ',"loW":', _jn(m[34]), ',"loH":', _jn(m[35]), "}")
            line += String(',"cast":{"rg":', _jn(m[19]), ',"by":', _jn(m[20]), "}")
            line += String(',"band":{"smooth":', _jn(m[21]), ',"eq":', _jn(m[22]), ',"jump":', _jn(m[23]), "}")
            line += String(',"haze":{"col":', _jn(m[25]), ',"colAt":', Int(m[26]), ',"row":', _jn(m[27]), ',"rowAt":', Int(m[28]), "}")
            line += String(',"dhash":"', _hex(hb, i * 128), '","phash":"', _hex(hb, i * 128 + 64), '","dupOf":[],"flags":[')
            for k in range(len(fl)):
                line += String("," if k > 0 else "", '"', fl[k], '"')
            line += "]}"
        line += "\n"
        out.write(line)
        if sidecar != 0:
            var sf = open(origs[i] + ".stockcheck.json", "w")
            sf.write(line)
    _ = (len(res), len(hb), len(dims), len(errs))
    return True


def _pos(r: Int) -> Int:
    return r


def _pos(r: Optional[Int]) -> Int:
    return r.or_else(-1)


def _field(line: String, key: String, stop: String) -> String:
    var s = _pos(line.find(key))
    if s < 0:
        return String()
    var b = s + key.byte_length()
    var e = _pos(line.find(stop, b))
    return String(line[byte=b:e]) if e >= 0 else String()


def _bits(hex: String) -> List[UInt8]:
    var w: UInt64 = 0
    for c in hex.codepoints():
        var d = Int(c.to_u32())
        w = (w << 4) | UInt64(d - 48 if d < 58 else d - 87)
    var o = List[UInt8](length=64, fill=0)
    for k in range(64):
        o[k] = UInt8((w >> UInt64(k)) & 1)
    return o^


def dups(mut a: Args) raises -> Bool:
    """stockDups OUT.jsonl IN.jsonl [dthr=10 pthr=10]: add near-duplicates across all lines of IN.jsonl (stockBatch
    output, possibly from several runs). Two images are twins when their dHash and pHash are both within the
    thresholds. Fills "dupOf", puts "duplicate" first in "flags", and ends the file with one {"dup":...} line per pair."""
    var lines = open(a.ins[0], "r").read().split("\n")
    var idx = List[Int]()  # line numbers that carry hashes
    var files = List[String]()
    var dd = List[UInt8]()
    var pp = List[UInt8]()
    for i in range(len(lines)):
        var l = String(lines[i])
        if _pos(l.find('"dhash":"')) < 0:
            continue
        idx.append(i)
        files.append(_field(l, '{"file":"', '","w":'))
        dd.extend(_bits(_field(l, '"dhash":"', '"')))
        pp.extend(_bits(_field(l, '"phash":"', '"')))
    var n = len(idx)
    var dm = Mat[DType.uint8](n, 64, 1)
    var pm = Mat[DType.uint8](n, 64, 1)
    for i in range(n * 64):
        dm.data[i] = dd[i]
        pm.data[i] = pp[i]
    var dthr = a.i("dthr", 10)
    var pthr = a.i("pthr", 10)
    var dpairs = ham_pairs(dm, dthr)
    var pmap = ham_pairs(pm, pthr)
    var pd = Dict[Int, Int]()
    for k in range(pmap.rows):
        pd[Int(pmap.data[3 * k]) * n + Int(pmap.data[3 * k + 1])] = Int(pmap.data[3 * k + 2])
    var of = List[String](length=n, fill=String())
    var tail = String()
    for k in range(dpairs.rows):
        var i = Int(dpairs.data[3 * k])
        var j = Int(dpairs.data[3 * k + 1])
        if i * n + j in pd:
            of[i] += String("," if of[i].byte_length() > 0 else "", '"', files[j], '"')
            of[j] += String("," if of[j].byte_length() > 0 else "", '"', files[i], '"')
            tail += String('{"dup":{"a":"', files[i], '","b":"', files[j], '","dhash":', Int(dpairs.data[3 * k + 2]), ',"phash":', pd[i * n + j], "}}\n")
    var out = open(a.out, "w")
    var at = 0
    for i in range(len(lines)):
        var l = String(lines[i])
        if at < n and idx[at] == i:
            if of[at].byte_length() > 0:
                l = l.replace('"dupOf":[]', String('"dupOf":[', of[at], "]"))
                l = l.replace('"flags":[]', '"flags":["duplicate"]').replace('"flags":["', '"flags":["duplicate","') if _pos(l.find('"flags":[]')) < 0 else l.replace('"flags":[]', '"flags":["duplicate"]')
            at += 1
        if l.byte_length() > 0:
            out.write(l + "\n")
    out.write(tail)
    return True


def run(mut a: Args) raises -> Bool:
    if not (a.op in ["sharpness", "noiseEst", "blockiness", "clipping", "colorCast", "banding", "hazeBand", "hashes", "hamPairs", "stockMetrics", "stockBatch", "stockDups", "boxDown", "jpegBgr"]):
        return False
    if a.op == "stockBatch":
        return batch(a)
    if a.op == "stockDups":
        return dups(a)
    if a.op == "jpegBgr":  # jpegBgr OUT.mcv IN.jpg [gpu=1]: tj3Decompress8, or the planes finished on the card (the parity gate)
        var o = Mat[DType.uint8](0, 0)
        if a.i("gpu", 0) == 1:
            var y = load_jpeg_yuv(a.ins[0])
            var g = StockGpu()
            while a.again():
                o = Mat[DType.uint8](copy=g.analyse(y, 1, True).bgr)
            print("GPU-ARM jpegBgr mode", y.mode)
        else:
            while a.again():
                o = load_jpeg(a.ins[0])
        save(o, a.out)
        return True
    var m = load[DType.uint8](a.ins[0])
    if a.op == "hamPairs":
        var o = Mat[DType.int32](0, 0)
        while a.again():
            o = ham_pairs(m, a.i("thr", 10))
        save(o, a.out)
    elif a.op == "hashes" or a.op == "boxDown":
        var o = Mat[DType.uint8](0, 0)
        while a.again():
            o = hashes(m) if a.op == "hashes" else box_down(m, a.i("f", 2))
        save(o, a.out)
    else:
        var o = Mat[F64](0, 0)
        while a.again():
            if a.op == "sharpness":
                o = sharpness(m, a.i("tile", 32), a.f("thr", 10.0))
            elif a.op == "noiseEst":
                o = noise_est(m)
            elif a.op == "blockiness":
                o = blockiness(m)
            elif a.op == "clipping":
                o = clipping(m, a.i("lo", 3), a.i("hi", 252))
            elif a.op == "colorCast":
                o = color_cast(m)
            elif a.op == "banding":
                o = banding(m, a.i("btile", 16), a.f("bstd", 6.0), a.i("brange", 3))
            elif a.op == "hazeBand":
                o = haze_band(m)
            else:
                o = stock_metrics(m, a)
        save(o, a.out)
    return True
