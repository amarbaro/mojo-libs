"""Pure Mojo JPEG decoder, no library, no FFI. `jpeg_decode(bytes)` returns (width, height, pixels) with the pixel packing and the
picture-size guard of `png_decode` (r | g << 8 | b << 16 | a << 24, a = 255).

Baseline, extended-sequential and progressive Huffman, 8-bit, 1 or 3 components, any 1 to 4 sampling factors (4:4:4, 4:2:2, 4:4:0,
4:2:0 get libjpeg's "fancy" triangle upsampling, others replicate), restart markers, APPn / COM segments skipped, Adobe transform
flag read. The IDCT is libjpeg's accurate integer one (jidctint) and the YCbCr conversion uses its fixed-point constants, so the
output sits within 1 to 2 levels of libjpeg-turbo. Arithmetic coding, lossless, 12-bit and 4-component (CMYK) files raise.

Every length is checked before it is used and a truncated entropy stream raises: the bit reader feeds zero bits after a marker or
the end of data and raises as soon as one of them is consumed.
Oracle: tests/jpeg_test.sh (ImageMagick writes the fixtures and the golden RGBA, never run time).
"""

from std.bit import byte_swap
from std.memory import bitcast
from std.utils import IndexList
from max.algorithm import parallelize

comptime MAXPX = 1 << 26  # same value as assets.MAXPX (tests/jpeg_test.mojo checks it): 64 M pixels
comptime P8 = Pointer[UInt8, MutAnyOrigin]
comptime P16 = Pointer[UInt16, MutAnyOrigin]
comptime PS = Pointer[Int16, MutAnyOrigin]
comptime PI = Pointer[Int, MutAnyOrigin]
comptime GW = 8  # blocks per group: the coefficients of GW consecutive blocks of a row are stored interleaved, k * GW + lane


struct Br(Copyable, Movable):
    """Entropy-coded bit reader, left-aligned: the top `nb` bits of `acc` are unread, the lowest `vb` of them are virtual zeros past a
    marker or the end. Refills 8 bytes at a time when none is 0xFF; a stuffed 0xFF00 or a marker takes the byte path."""

    var acc: UInt64
    var nb: Int
    var vb: Int
    var pos: Int
    var n: Int
    var a: Int  # address of the data
    var stop: Bool

    def __init__(out self, a: Int, n: Int):
        self.acc, self.nb, self.vb, self.pos, self.n, self.a, self.stop = 0, 0, 0, 0, n, a, False

    def reset(mut self):
        self.acc, self.nb, self.vb, self.stop = 0, 0, 0, False

    @always_inline
    def refill(mut self):
        """Top up to 57..64 bits."""
        if self.stop:
            var k = (64 - self.nb) >> 3
            self.nb += 8 * k
            self.vb += 8 * k
        elif self.pos + 8 <= self.n:
            var v = byte_swap(bitcast[DType.uint64, 1](P8(unsafe_from_address=self.a).unsafe_load[width=8](self.pos))[0])
            var x = ~v
            if ((x - 0x0101010101010101) & ~x & 0x8080808080808080) == 0:  # no 0xFF byte in the 8
                self.acc |= v >> UInt64(self.nb)
                var k = (64 - self.nb) >> 3
                self.pos += k
                self.nb += 8 * k
            else:
                self.slow()
        else:
            self.slow()

    @no_inline
    def slow(mut self):
        var p = P8(unsafe_from_address=self.a)
        while self.nb <= 56:
            if self.stop:
                self.nb += 8
                self.vb += 8
                continue
            if self.pos >= self.n:
                self.stop = True
                continue
            var b = p.unsafe_load(self.pos)
            if b == 0xFF:
                if self.pos + 1 >= self.n:
                    self.stop = True
                    continue
                var c = p.unsafe_load(self.pos + 1)
                if c == 0xFF:  # fill byte
                    self.pos += 1
                    continue
                if c != 0:  # a marker ends the entropy-coded data
                    self.stop = True
                    continue
                self.pos += 2
            else:
                self.pos += 1
            self.acc |= UInt64(b) << UInt64(56 - self.nb)
            self.nb += 8

    @always_inline
    def drop(mut self, n: Int):
        self.acc <<= UInt64(n)
        self.nb -= n

    def chk(self) raises:
        """Raise if a virtual bit was consumed."""
        if self.nb < self.vb:
            raise Error("jpeg: truncated entropy-coded data")


@fieldwise_init
struct Comp(Copyable, Movable):
    var id: Int
    var h: Int  # sampling factors
    var v: Int
    var tq: Int  # quantization table id
    var bw: Int  # blocks per row / column of the coefficient grid, padded to whole MCUs
    var bh: Int
    var nbx: Int  # blocks per row / column that hold picture, the walk of a one-component scan
    var nby: Int
    var dw: Int  # samples per row / rows of picture
    var dh: Int
    var coff: Int  # offset of this component in `co` and in `pl`
    var poff: Int
    var dc: Int  # Huffman table ids of the current scan
    var ac: Int
    var pred: Int  # DC predictor
    var q: Int  # offset of the latched quantization table in `qv`, -1 until the first scan
    var bwp: Int  # bw padded to whole groups of GW blocks
    var pw: Int  # plane row stride, bwp * 8


comptime V = SIMD[DType.int32, GW]


@always_inline
def tr8[sh: Int](mut w0: V, mut w1: V, mut w2: V, mut w3: V, mut w4: V, mut w5: V, mut w6: V, mut w7: V):
    """libjpeg jidctint 1-D inverse DCT of 8 vectors, one lane per block, in place, descaled by `sh` bits."""
    var z1 = (w2 + w6) * 4433
    var t2 = z1 - w6 * 15137
    var t3 = z1 + w2 * 6270
    comptime s = V(sh)
    comptime r = V(1 << (sh - 1))  # rounding, folded into t0 and t1
    var t0 = ((w0 + w4) << 13) + r
    var t1 = ((w0 - w4) << 13) + r
    var t10 = t0 + t3
    var t13 = t0 - t3
    var t11 = t1 + t2
    var t12 = t1 - t2
    z1 = w7 + w1
    var z2 = w5 + w3
    var z3 = w7 + w3
    var z4 = w5 + w1
    var z5 = (z3 + z4) * 9633
    var a0 = w7 * 2446 + z1 * -7373 + z3 * -16069 + z5
    var a1 = w5 * 16819 + z2 * -20995 + z4 * -3196 + z5
    var a2 = w3 * 25172 + z2 * -20995 + z3 * -16069 + z5
    var a3 = w1 * 12299 + z1 * -7373 + z4 * -3196 + z5
    w0 = (t10 + a3) >> s
    w7 = (t10 - a3) >> s
    w1 = (t11 + a2) >> s
    w6 = (t11 - a2) >> s
    w2 = (t12 + a1) >> s
    w5 = (t12 - a1) >> s
    w3 = (t13 + a0) >> s
    w4 = (t13 - a0) >> s


@always_inline
def ld(co: PS, q: Pointer[Int32, MutAnyOrigin], k: Int) -> V:
    """Dequantized coefficient k of the group (one lane per block); the coefficients read are zeroed for the next row."""
    var v = (co + k * GW).unsafe_load[width=GW]().cast[DType.int32]() * (q + k * GW).unsafe_load[width=GW]()
    (co + k * GW).unsafe_store(0, SIMD[DType.int16, GW](0))
    return v


def _tmask() -> IndexList[8 * GW]:
    """Lane-major (sample j of block b at j * GW + b) to block-major (b * 8 + j)."""
    var m = IndexList[8 * GW]()
    for b in range(GW):
        for j in range(8):
            m[b * 8 + j] = j * GW + b
    return m


def idct_g(co: PS, q: Pointer[Int32, MutAnyOrigin], ws: Pointer[Int32, MutAnyOrigin], px: P8, pw: Int):
    """Dequantize and inverse-transform the GW blocks of the group at co into 8 rows of GW * 8 samples at px (row stride pw)."""
    comptime for j in range(8):
        var w0, w1, w2, w3 = ld(co, q, j), ld(co, q, 8 + j), ld(co, q, 16 + j), ld(co, q, 24 + j)
        var w4, w5, w6, w7 = ld(co, q, 32 + j), ld(co, q, 40 + j), ld(co, q, 48 + j), ld(co, q, 56 + j)
        tr8[11](w0, w1, w2, w3, w4, w5, w6, w7)
        ws.unsafe_store(j * GW, w0)
        ws.unsafe_store((8 + j) * GW, w1)
        ws.unsafe_store((16 + j) * GW, w2)
        ws.unsafe_store((24 + j) * GW, w3)
        ws.unsafe_store((32 + j) * GW, w4)
        ws.unsafe_store((40 + j) * GW, w5)
        ws.unsafe_store((48 + j) * GW, w6)
        ws.unsafe_store((56 + j) * GW, w7)
    comptime for i in range(8):
        var w0, w1, w2, w3 = ws.unsafe_load[width=GW](i * 8 * GW), ws.unsafe_load[width=GW]((i * 8 + 1) * GW), ws.unsafe_load[width=GW]((i * 8 + 2) * GW), ws.unsafe_load[width=GW]((i * 8 + 3) * GW)
        var w4, w5, w6, w7 = ws.unsafe_load[width=GW]((i * 8 + 4) * GW), ws.unsafe_load[width=GW]((i * 8 + 5) * GW), ws.unsafe_load[width=GW]((i * 8 + 6) * GW), ws.unsafe_load[width=GW]((i * 8 + 7) * GW)
        tr8[18](w0, w1, w2, w3, w4, w5, w6, w7)
        var o0 = (w0 + 128).clamp(0, 255).cast[DType.uint8]()
        var o1 = (w1 + 128).clamp(0, 255).cast[DType.uint8]()
        var o2 = (w2 + 128).clamp(0, 255).cast[DType.uint8]()
        var o3 = (w3 + 128).clamp(0, 255).cast[DType.uint8]()
        var o4 = (w4 + 128).clamp(0, 255).cast[DType.uint8]()
        var o5 = (w5 + 128).clamp(0, 255).cast[DType.uint8]()
        var o6 = (w6 + 128).clamp(0, 255).cast[DType.uint8]()
        var o7 = (w7 + 128).clamp(0, 255).cast[DType.uint8]()
        var x = o0.join(o1).join(o2.join(o3)).join(o4.join(o5).join(o6.join(o7)))
        (px + i * pw).unsafe_store(0, x.shuffle[_tmask()]())


def clamp8(v: Int) -> Int:
    return min(max(v, 0), 255)


comptime UW = 32  # input samples per step of the 2:1 upsampler
comptime CW = 16  # pixels per step of the colour conversion


@always_inline
def _s(a: P8, b: P8, i: Int, va: SIMD[DType.uint16, UW], vb: SIMD[DType.uint16, UW]) -> SIMD[DType.uint16, UW]:
    return (a + i).unsafe_load[width=UW]().cast[DType.uint16]() * va + (b + i).unsafe_load[width=UW]().cast[DType.uint16]() * vb


def h2(a: P8, b: P8, o: P8, dw: Int, wa: Int, wb: Int, be: Int, bo: Int):
    """libjpeg's fancy 2:1 triangle filter (h2v1, h2v2) of the column sums s = wa * a + wb * b, dw samples into o[0 .. 2 * dw):
    o[2i] = (3 s[i] + s[i-1] + be) >> 4, o[2i+1] = (3 s[i] + s[i+1] + bo) >> 4, the edge sample counts twice."""
    var i = 0
    var va, vb = SIMD[DType.uint16, UW](wa), SIMD[DType.uint16, UW](wb)
    var ve, vo = SIMD[DType.uint16, UW](be), SIMD[DType.uint16, UW](bo)
    while i < dw:
        if i > 0 and i + UW + 1 <= dw:  # whole steps: every load is inside the row
            var sc = _s(a, b, i, va, vb)
            var ev = (sc * 3 + _s(a, b, i - 1, va, vb) + ve) >> 4
            var od = (sc * 3 + _s(a, b, i + 1, va, vb) + vo) >> 4
            (o + 2 * i).unsafe_store(0, ev.cast[DType.uint8]().interleave(od.cast[DType.uint8]()))
            i += UW
            continue
        var sc = wa * Int(a.unsafe_load(i)) + wb * Int(b.unsafe_load(i))
        var sp = sc if i == 0 else wa * Int(a.unsafe_load(i - 1)) + wb * Int(b.unsafe_load(i - 1))
        var sn = sc if i == dw - 1 else wa * Int(a.unsafe_load(i + 1)) + wb * Int(b.unsafe_load(i + 1))
        o.unsafe_store(2 * i, UInt8((3 * sc + sp + be) >> 4))
        o.unsafe_store(2 * i + 1, UInt8((3 * sc + sn + bo) >> 4))
        i += 1


def _imask() -> IndexList[4 * CW]:
    """Planar r, g, b (the 4th vector is padding) to packed rgb in the first 3 * CW lanes."""
    var m = IndexList[4 * CW]()
    for i in range(4 * CW):
        m[i] = (i % 3) * CW + i // 3 if i < 3 * CW else 0
    return m


def pack[mode: Int](a: P8, b: P8, c: P8, o: P8, w: Int):
    """w pixels of one row to packed RGB at o. mode 0: a, b, c = Y, Cb, Cr (libjpeg fixed point); 1: R, G, B planes; 2: grey in a.
    The vector store writes CW padding bytes past its 3 * CW, so the last two steps of the row are left to the scalar loop."""
    var x = 0
    while x + 2 * CW <= w:
        var r = (a + x).unsafe_load[width=CW]()
        var g = r
        var bl = r
        comptime if mode == 1:
            g = (b + x).unsafe_load[width=CW]()
            bl = (c + x).unsafe_load[width=CW]()
        elif mode == 0:
            var l = r.cast[DType.int32]()
            var cb = (b + x).unsafe_load[width=CW]().cast[DType.int32]() - 128
            var cr = (c + x).unsafe_load[width=CW]().cast[DType.int32]() - 128
            r = (l + ((cr * 91881 + 32768) >> 16)).clamp(0, 255).cast[DType.uint8]()
            g = (l + ((cb * -22554 + cr * -46802 + 32768) >> 16)).clamp(0, 255).cast[DType.uint8]()
            bl = (l + ((cb * 116130 + 32768) >> 16)).clamp(0, 255).cast[DType.uint8]()
        (o + 3 * x).unsafe_store(0, r.join(g).join(bl.join(bl)).shuffle[_imask()]())
        x += CW
    for t in range(x, w):
        var l = Int(a.unsafe_load(t))
        var r, g, bl = l, l, l
        comptime if mode == 1:
            g, bl = Int(b.unsafe_load(t)), Int(c.unsafe_load(t))
        elif mode == 0:
            var cb, cr = Int(b.unsafe_load(t)) - 128, Int(c.unsafe_load(t)) - 128
            r = clamp8(l + ((91881 * cr + 32768) >> 16))
            g = clamp8(l + ((-22554 * cb - 46802 * cr + 32768) >> 16))
            bl = clamp8(l + ((116130 * cb + 32768) >> 16))
        o.unsafe_store(3 * t, UInt8(r))
        o.unsafe_store(3 * t + 1, UInt8(g))
        o.unsafe_store(3 * t + 2, UInt8(bl))


struct Jpeg(Movable):
    var d: List[UInt8]
    var br: Br  # bit reader; br.pos is also the marker-segment cursor of parse
    var eobrun: Int
    var ss: Int  # scan parameters
    var se: Int
    var ah: Int
    var al: Int
    var ri: Int  # restart interval
    var adobe: Int  # Adobe transform flag, -1 none
    var jfif: Bool
    var maxpx: Int  # largest w * h decoded; MAXPX unless the caller raises it
    var prog: Bool
    var w: Int
    var h: Int
    var hm: Int  # largest sampling factors
    var vm: Int
    var mcux: Int
    var mcuy: Int
    var zz: List[Int]
    var qt: List[Int]  # 4 tables x 64, natural order
    var qv: List[Int32]  # latched tables, 64 per component, each entry repeated GW times (one per lane)
    var lk: List[UInt16]  # per Huffman table (DC 0-3, AC 4-7): 9-bit lookahead (len << 8 | symbol), 0 = longer code
    var mc: List[Int]  # largest code of each length, -1 = none
    var vo: List[Int]  # value index = code + vo[length]
    var hv: List[Int]  # symbols
    var hdef: List[Bool]
    var comps: List[Comp]
    var co: List[Int16]  # coefficients, natural order, 64 per block; a baseline file keeps one block here and transforms it at once
    var ws: List[Int32]  # IDCT workspace: 64 vectors of GW lanes
    var pl: List[UInt8]  # decoded planes

    def __init__(out self, src: Span[UInt8, _]):
        self.d = List[UInt8]()
        self.d.extend(src)
        self.br = Br(Int(self.d.unsafe_ptr()), len(self.d))
        self.eobrun = 0
        self.ss = 0
        self.se = 63
        self.ah = 0
        self.al = 0
        self.ri = 0
        self.adobe = -1
        self.jfif = False
        self.maxpx = MAXPX
        self.prog = False
        self.w = 0
        self.h = 0
        self.hm = 1
        self.vm = 1
        self.mcux = 0
        self.mcuy = 0
        self.zz = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
        self.qt = List[Int](length=256, fill=1)
        self.qv = List[Int32]()
        self.lk = List[UInt16](length=8 * 512, fill=0)
        self.mc = List[Int](length=8 * 18, fill=-1)
        self.vo = List[Int](length=8 * 18, fill=0)
        self.hv = List[Int](length=8 * 256, fill=0)
        self.hdef = List[Bool](length=8, fill=False)
        self.comps = List[Comp]()
        self.co = List[Int16]()
        self.ws = List[Int32](length=64 * GW, fill=0)
        self.pl = List[UInt8]()

    def be16(self, i: Int) -> Int:
        return Int(self.d[i]) << 8 | Int(self.d[i + 1])

    # ---- bit reader (progressive and refinement scans; the baseline loop in `base` keeps its own copy in registers) ----

    def get(mut self, n: Int) raises -> Int:
        if n == 0:
            return 0
        if self.br.nb < n:
            self.br.refill()
        var v = Int(self.br.acc >> UInt64(64 - n))
        self.br.drop(n)
        self.br.chk()
        return v

    def ext(mut self, s: Int) raises -> Int:
        """s bits as a signed magnitude (JPEG EXTEND)."""
        if s == 0:
            return 0
        var v = self.get(s)
        return v if v >= (1 << (s - 1)) else v - (1 << s) + 1

    def slowcode(self, w: Int, t: Int) raises -> Tuple[Int, Int]:
        """Length and symbol of a code longer than 9 bits; w = the next 16 bits."""
        for l in range(10, 17):
            var code = w >> (16 - l)
            if code <= self.mc[t * 18 + l]:
                return (l, self.hv[t * 256 + self.vo[t * 18 + l] + code])
        raise Error("jpeg: bad Huffman code")

    def huff(mut self, t: Int) raises -> Int:
        if self.br.nb < 16:
            self.br.refill()
        var e = Int(self.lk[t * 512 + Int(self.br.acc >> 55)])
        var l, sym = e >> 8, e & 255
        if e == 0:
            l, sym = self.slowcode(Int(self.br.acc >> 48), t)
        self.br.drop(l)
        self.br.chk()
        return sym

    def restart(mut self) raises:
        var n = len(self.d)
        while self.br.pos + 1 < n and not (self.d[self.br.pos] == 0xFF and self.d[self.br.pos + 1] != 0 and self.d[self.br.pos + 1] != 0xFF):
            self.br.pos += 1
        if self.br.pos + 1 >= n:
            raise Error("jpeg: truncated, restart marker missing")
        var m = Int(self.d[self.br.pos + 1])
        if m < 0xD0 or m > 0xD7:
            raise Error("jpeg: restart marker expected, found FF" + hex(m))
        self.br.pos += 2
        self.br.reset()
        self.eobrun = 0
        for i in range(len(self.comps)):
            self.comps[i].pred = 0

    # ---- marker segments ----

    def dqt(mut self, s: Int, e: Int) raises:
        var i = s
        while i < e:
            var pq, tq = Int(self.d[i]) >> 4, Int(self.d[i]) & 15
            i += 1
            if tq > 3 or pq > 1 or i + 64 * (pq + 1) > e:
                raise Error("jpeg: bad DQT")
            for k in range(64):
                self.qt[tq * 64 + self.zz[k]] = self.be16(i + 2 * k) if pq == 1 else Int(self.d[i + k])
            i += 64 * (pq + 1)

    def dht(mut self, s: Int, e: Int) raises:
        var i = s
        while i < e:
            if i + 17 > e:
                raise Error("jpeg: bad DHT")
            var tc, th = Int(self.d[i]) >> 4, Int(self.d[i]) & 15
            var total = 0
            for l in range(1, 17):
                total += Int(self.d[i + l])
            if tc > 1 or th > 3 or total > 256 or i + 17 + total > e:
                raise Error("jpeg: bad DHT")
            var t = tc * 4 + th
            for k in range(512):
                self.lk[t * 512 + k] = 0
            var code, k = 0, 0
            for l in range(1, 17):
                var n = Int(self.d[i + l])
                self.vo[t * 18 + l] = k - code
                for _ in range(n):
                    if l <= 9:
                        var sym = Int(self.d[i + 17 + k])
                        for f in range(code << (9 - l), (code + 1) << (9 - l)):
                            self.lk[t * 512 + f] = UInt16(l << 8 | sym)
                    self.hv[t * 256 + k] = Int(self.d[i + 17 + k])
                    code += 1
                    k += 1
                if code > (1 << l):
                    raise Error("jpeg: Huffman table over-subscribed")
                self.mc[t * 18 + l] = code - 1 if n > 0 else -1
                code <<= 1
            self.hdef[t] = True
            i += 17 + total

    def sof(mut self, prog: Bool, s: Int, e: Int) raises:
        if len(self.comps) > 0:
            raise Error("jpeg: two SOF markers")
        if e - s < 6 or self.d[s] != 8:
            raise Error("jpeg: only 8-bit samples")
        self.prog = prog
        self.h, self.w = self.be16(s + 1), self.be16(s + 3)
        var nf = Int(self.d[s + 5])
        if self.w < 1 or self.h < 1:
            raise Error("jpeg: empty picture")
        if self.w * self.h > self.maxpx:  # before any allocation that grows with w * h
            raise Error("jpeg: " + String(self.w) + " x " + String(self.h) + " is too large (" + String(self.maxpx) + " pixels at most)")
        if nf == 4:
            raise Error("jpeg: 4 components (CMYK / YCCK) not supported")
        if nf != 1 and nf != 3:
            raise Error("jpeg: " + String(nf) + " components not supported")
        if e - s != 6 + 3 * nf:
            raise Error("jpeg: bad SOF length")
        for i in range(nf):
            var p = s + 6 + 3 * i
            var hh, vv, tq = Int(self.d[p + 1]) >> 4, Int(self.d[p + 1]) & 15, Int(self.d[p + 2])
            if nf == 1:  # a one-component scan is one block per MCU whatever the factors say
                hh, vv = 1, 1
            if hh < 1 or hh > 4 or vv < 1 or vv > 4 or tq > 3:
                raise Error("jpeg: bad component " + String(i))
            self.hm, self.vm = max(self.hm, hh), max(self.vm, vv)
            self.comps.append(Comp(Int(self.d[p]), hh, vv, tq, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0, 0))
        self.mcux = (self.w + 8 * self.hm - 1) // (8 * self.hm)
        self.mcuy = (self.h + 8 * self.vm - 1) // (8 * self.vm)
        var nco, npl = 0, 0
        for i in range(nf):
            var c = self.comps[i].copy()
            c.bw, c.bh = self.mcux * c.h, self.mcuy * c.v
            c.dw, c.dh = (self.w * c.h + self.hm - 1) // self.hm, (self.h * c.v + self.vm - 1) // self.vm
            c.nbx, c.nby = (c.dw + 7) // 8, (c.dh + 7) // 8
            c.bwp = (c.bw + GW - 1) // GW * GW
            c.pw = c.bwp * 8
            c.coff, c.poff = nco, npl
            nco += c.bwp * (c.bh if prog else c.v) * 64  # a baseline file holds one MCU row of blocks at a time
            npl += c.bwp * c.bh * 64
            self.comps[i] = c^
        self.co = List[Int16](length=nco, fill=0)
        self.pl = List[UInt8](length=npl, fill=0)
        self.qv = List[Int32](length=64 * GW * nf, fill=1)

    def sos(mut self, s: Int, e: Int) raises:
        var nf = len(self.comps)
        if nf == 0:
            raise Error("jpeg: scan before SOF")
        var ns = Int(self.d[s])
        if ns < 1 or ns > nf or e - s != 4 + 2 * ns:
            raise Error("jpeg: bad SOS")
        var sc = List[Int]()
        for i in range(ns):
            var c = -1
            for k in range(nf):
                if self.comps[k].id == Int(self.d[s + 1 + 2 * i]):
                    c = k
            if c < 0 or c in sc:
                raise Error("jpeg: scan names an unknown or repeated component")
            var tt = Int(self.d[s + 2 + 2 * i])
            if (tt >> 4) > 3 or (tt & 15) > 3:
                raise Error("jpeg: bad Huffman table id")
            self.comps[c].dc, self.comps[c].ac = tt >> 4, 4 + (tt & 15)
            sc.append(c)
        var q = 2 * ns
        self.ss, self.se = Int(self.d[s + 1 + q]), Int(self.d[s + 2 + q])
        self.ah, self.al = Int(self.d[s + 3 + q]) >> 4, Int(self.d[s + 3 + q]) & 15
        if not self.prog:
            self.ss, self.se, self.ah, self.al = 0, 63, 0, 0
        elif self.ss > self.se or self.se > 63 or self.al > 13 or (self.ss == 0 and self.se != 0) or (self.ss > 0 and ns != 1) or (self.ah != 0 and self.ah != self.al + 1):
            raise Error("jpeg: bad progressive scan parameters")
        for c in sc:
            if self.comps[c].q < 0:  # a component keeps the table it first scanned with
                self.comps[c].q = 64 * c
                for k in range(64):
                    for l in range(GW):
                        self.qv[(64 * c + k) * GW + l] = Int32(self.qt[self.comps[c].tq * 64 + k])
            if (not self.prog or (self.ss == 0 and self.ah == 0)) and not self.hdef[self.comps[c].dc]:
                raise Error("jpeg: DC Huffman table missing")
            if (not self.prog or self.ss > 0) and not self.hdef[self.comps[c].ac]:
                raise Error("jpeg: AC Huffman table missing")
        self.br.reset()
        self.eobrun = 0
        for c in sc:
            self.comps[c].pred = 0
        self.scan(sc)

    # ---- entropy-coded data ----

    def scan(mut self, sc: List[Int]) raises:
        var one = len(sc) == 1
        var nx, ny = self.mcux, self.mcuy
        if one:
            nx, ny = self.comps[sc[0]].nbx, self.comps[sc[0]].nby
        for m in range(nx * ny):
            if self.ri > 0 and m > 0 and m % self.ri == 0:
                self.restart()
            var mx, my = m % nx, m // nx
            for c in sc:
                var h, v = (1, 1) if one else (self.comps[c].h, self.comps[c].v)
                for vy in range(v):
                    for hx in range(h):
                        self.block(c, self.boff(c, vy if not self.prog else my * v + vy, mx * h + hx))
            if not self.prog and mx == nx - 1:  # a baseline row of blocks is complete: transform it
                for c in sc:
                    for vy in range(1 if one else self.comps[c].v):
                        self.flush(c, my if one else my * self.comps[c].v + vy, vy)

    def boff(self, c: Int, row: Int, bx: Int) -> Int:
        """Offset in `co` of the first coefficient of block column bx in buffer row `row` of component c."""
        return self.comps[c].coff + ((row * (self.comps[c].bwp // GW) + bx // GW) * 64 * GW + bx % GW)

    def base(mut self, c: Int, o: Int) raises:
        """Baseline block: Huffman-decode into the group slot at co[o], coefficient k at o + k * GW; the bit buffer lives in locals."""
        var dc, ac = self.comps[c].dc, self.comps[c].ac
        var br = self.br.copy()
        var co = self.co.unsafe_ptr()
        var zz = self.zz.unsafe_ptr()
        var lk = self.lk.unsafe_ptr()
        if br.nb < 32:
            br.refill()
        var e = Int(lk.unsafe_load(dc * 512 + Int(br.acc >> 55)))
        var l, s = e >> 8, e & 255
        if e == 0:
            l, s = self.slowcode(Int(br.acc >> 48), dc)
        br.drop(l)
        if s > 15:
            raise Error("jpeg: bad DC category")
        var df = 0
        if s > 0:
            df = Int(br.acc >> UInt64(64 - s))
            br.drop(s)
            df += ((df >> (s - 1)) - 1) & (1 - (1 << s))
        self.comps[c].pred += df
        co.unsafe_store(o, Int16(self.comps[c].pred))
        var k = 1
        while k < 64:
            if br.nb < 32:
                br.refill()
            e = Int(lk.unsafe_load(ac * 512 + Int(br.acc >> 55)))
            l, s = e >> 8, e & 255
            if e == 0:
                l, s = self.slowcode(Int(br.acc >> 48), ac)
            br.drop(l)
            var r = s >> 4
            s &= 15
            if s == 0:
                if r != 15:
                    break
                k += 16
                continue
            k += r
            if k > 63:
                raise Error("jpeg: coefficient index past 63")
            var v = Int(br.acc >> UInt64(64 - s))
            br.drop(s)
            v += ((v >> (s - 1)) - 1) & (1 - (1 << s))
            co.unsafe_store(o + Int(zz.unsafe_load(k)) * GW, Int16(v))
            k += 1
        br.chk()
        self.br = br^

    def block(mut self, c: Int, o: Int) raises:
        if not self.prog:
            self.base(c, o)
        elif self.ss == 0:
            if self.ah == 0:
                var s = self.huff(self.comps[c].dc)
                if s > 15:
                    raise Error("jpeg: bad DC category")
                var df = self.ext(s)
                self.comps[c].pred += df
                self.co[o] = Int16(self.comps[c].pred * (1 << self.al))
            elif self.get(1) == 1:
                self.co[o] = self.co[o] | Int16(1 << self.al)
        elif self.ah == 0:
            if self.eobrun > 0:
                self.eobrun -= 1
                return
            var k = self.ss
            while k <= self.se:
                var rs = self.huff(self.comps[c].ac)
                var r, sz = rs >> 4, rs & 15
                if sz != 0:
                    k += r
                    if k > self.se:
                        raise Error("jpeg: coefficient index past the band")
                    self.co[o + self.zz[k] * GW] = Int16(self.ext(sz) * (1 << self.al))
                elif r == 15:
                    k += 15
                else:
                    self.eobrun = (1 << r) - 1 + (self.get(r) if r > 0 else 0)
                    break
                k += 1
        else:
            self.refine(c, o)

    def refine(mut self, c: Int, o: Int) raises:
        """AC successive-approximation refinement scan of one block (libjpeg decode_mcu_AC_refine)."""
        var p1, m1 = 1 << self.al, -1 << self.al
        var k = self.ss
        if self.eobrun == 0:
            while k <= self.se:
                var rs = self.huff(self.comps[c].ac)
                var r, s = rs >> 4, rs & 15
                if s != 0:
                    if s != 1:
                        raise Error("jpeg: bad refinement symbol")
                    s = p1 if self.get(1) == 1 else m1
                elif r != 15:
                    self.eobrun = 1 << r
                    if r > 0:
                        self.eobrun += self.get(r)
                    break
                while k <= self.se:  # step over the nonzero coefficients (refining them) and r zero ones
                    var i = o + self.zz[k] * GW
                    var cf = Int(self.co[i])
                    if cf != 0:
                        if self.get(1) == 1 and (cf & p1) == 0:
                            self.co[i] = Int16(cf + (p1 if cf >= 0 else m1))
                    else:
                        r -= 1
                        if r < 0:
                            break
                    k += 1
                if s != 0:
                    if k > self.se:
                        raise Error("jpeg: refinement past the band")
                    self.co[o + self.zz[k] * GW] = Int16(s)
                k += 1
        if self.eobrun > 0:
            while k <= self.se:
                var i = o + self.zz[k] * GW
                var cf = Int(self.co[i])
                if cf != 0 and self.get(1) == 1 and (cf & p1) == 0:
                    self.co[i] = Int16(cf + (p1 if cf >= 0 else m1))
                k += 1
            self.eobrun -= 1

    # ---- the file ----

    def parse(mut self) raises:
        var n = len(self.d)
        if n < 4 or self.d[0] != 0xFF or self.d[1] != 0xD8:
            raise Error("jpeg: not a JPEG")
        self.br.pos = 2
        var scans = 0
        while True:
            while self.br.pos < n and self.d[self.br.pos] != 0xFF:  # entropy data left over, or garbage between segments
                self.br.pos += 1
            while self.br.pos < n and self.d[self.br.pos] == 0xFF:
                self.br.pos += 1
            if self.br.pos >= n:
                raise Error("jpeg: truncated, no EOI")
            var m = Int(self.d[self.br.pos])
            self.br.pos += 1
            if m == 0 or m == 1 or (m >= 0xD0 and m <= 0xD7):
                continue
            if m == 0xD9:
                break
            if self.br.pos + 2 > n:
                raise Error("jpeg: truncated segment")
            var s, e = self.br.pos + 2, self.br.pos + self.be16(self.br.pos)
            if e < s or e > n:
                raise Error("jpeg: truncated segment")
            self.br.pos = e
            if m == 0xDB:
                self.dqt(s, e)
            elif m == 0xC4:
                self.dht(s, e)
            elif m == 0xDD:
                if e - s != 2:
                    raise Error("jpeg: bad DRI")
                self.ri = self.be16(s)
            elif m == 0xEE and e - s >= 12 and self.d[s] == 0x41 and self.d[s + 1] == 0x64 and self.d[s + 2] == 0x6F:  # "Ado"
                self.adobe = Int(self.d[s + 11])
            elif m == 0xE0 and e - s >= 5 and self.d[s] == 0x4A and self.d[s + 1] == 0x46:  # "JF"
                self.jfif = True
            elif m == 0xC0 or m == 0xC1 or m == 0xC2:
                self.sof(m == 0xC2, s, e)
            elif m == 0xC3 or (m >= 0xC5 and m <= 0xCF and m != 0xC8 and m != 0xCC):
                raise Error("jpeg: unsupported process, SOF" + hex(m - 0xC0) + " (lossless, hierarchical or arithmetic)")
            elif m == 0xDA:
                self.sos(s, e)
                scans += 1
        if scans == 0:
            raise Error("jpeg: no image data")

    def flush(mut self, c: Int, br: Int, row: Int):
        """Transform block row br of component c, whose coefficients sit in buffer row `row`, into the plane."""
        var k = self.comps[c].copy()
        var co = PS(unsafe_from_address=Int(self.co.unsafe_ptr())) + k.coff + row * k.bwp * 64
        var q = Pointer[Int32, MutAnyOrigin](unsafe_from_address=Int(self.qv.unsafe_ptr())) + 64 * GW * c
        var px = P8(unsafe_from_address=Int(self.pl.unsafe_ptr())) + k.poff + br * 8 * k.pw
        var ws = Pointer[Int32, MutAnyOrigin](unsafe_from_address=Int(self.ws.unsafe_ptr()))
        for g in range(k.bwp // GW):
            idct_g(co + g * 64 * GW, q, ws, px + g * GW * 8, k.pw)

    def idct(mut self):
        """Progressive files: transform every block once all scans are in, then drop the coefficients."""
        if self.prog:
            for c in range(len(self.comps)):
                for br in range(self.comps[c].bh):
                    self.flush(c, br, br)
        self.co = List[Int16]()

    def row(self, c: Int, y: Int, o: P8) -> P8:
        """Row y of component c at full width: a pointer into the plane when no resampling is needed, else `o` filled with libjpeg's
        fancy upsampling where it has one (h2v1, h2v2) and a simple filter or replication otherwise."""
        var k = self.comps[c].copy()
        var pl = P8(unsafe_from_address=Int(self.pl.unsafe_ptr()))
        var r0 = k.poff + (y * k.v // self.vm) * k.pw
        if k.h == self.hm and k.v == self.vm:
            return pl + r0
        var tall = k.v * 2 == self.vm
        var sy = y >> 1 if tall else y
        var oy = max(sy - 1, 0) if y % 2 == 0 else min(sy + 1, k.dh - 1)  # the nearer other row, used by the 2-high cases
        r0 = k.poff + sy * k.pw
        var r1 = k.poff + oy * k.pw
        if k.h * 2 == self.hm and k.dw > 2 and (k.v == self.vm or tall):  # h2v1 and h2v2
            if tall:
                h2(pl + r0, pl + r1, o, k.dw, 3, 1, 8, 7)
            else:
                h2(pl + r0, pl + r0, o, k.dw, 4, 0, 4, 8)
        elif k.h == self.hm and tall:  # h1v2
            for x in range(self.w):
                o.unsafe_store(x, UInt8((3 * Int(pl.unsafe_load(r0 + x)) + Int(pl.unsafe_load(r1 + x)) + (1 if y % 2 == 0 else 2)) >> 2))
        else:  # replicate
            r0 = k.poff + (y * k.v // self.vm) * k.pw
            for x in range(self.w):
                o.unsafe_store(x, pl.unsafe_load(r0 + x * k.h // self.hm))
        return o

    def rgb[par: Int = 1](self) -> List[UInt8]:
        """Packed R, G, B bytes, w * h * 3; the colour-model branch is hoisted out of the pixel loop. `par` > 1 splits the rows into
        that many bands on as many threads (default 1: serial)."""
        var px = List[UInt8](unsafe_uninit_length=self.w * self.h * 3)
        var pp = P8(unsafe_from_address=Int(px.unsafe_ptr()))
        var n = 2 * self.comps[0].pw + 128
        var buf = List[UInt8](length=3 * n * par, fill=0)
        var bp = P8(unsafe_from_address=Int(buf.unsafe_ptr()))
        var grey = len(self.comps) == 1
        var rgb = not grey and (self.adobe == 0 or (self.adobe < 0 and not self.jfif and self.comps[0].id == 0x52 and self.comps[1].id == 0x47 and self.comps[2].id == 0x42))

        def band(i: Int) {imm}:
            var t = bp + 3 * n * i
            for y in range(self.h * i // par, self.h * (i + 1) // par):
                var a = self.row(0, y, t)
                if grey:
                    pack[2](a, a, a, pp + y * self.w * 3, self.w)
                    continue
                var b = self.row(1, y, t + n)
                var c = self.row(2, y, t + 2 * n)
                if rgb:
                    pack[1](a, b, c, pp + y * self.w * 3, self.w)
                else:
                    pack[0](a, b, c, pp + y * self.w * 3, self.w)

        comptime if par == 1:
            band(0)
        else:
            parallelize(band, par, par)
        return px^

    def pixels(self) -> List[UInt32]:
        var px = List[UInt32](length=self.w * self.h, fill=0)
        var n = 2 * self.comps[0].pw + 128
        var buf = List[UInt8](length=3 * n, fill=0)
        var bp = P8(unsafe_from_address=Int(buf.unsafe_ptr()))
        var grey = len(self.comps) == 1
        var rgb = not grey and (self.adobe == 0 or (self.adobe < 0 and not self.jfif and self.comps[0].id == 0x52 and self.comps[1].id == 0x47 and self.comps[2].id == 0x42))
        for y in range(self.h):
            var a = self.row(0, y, bp)
            var b = a
            var c = a
            if not grey:
                b = self.row(1, y, bp + n)
                c = self.row(2, y, bp + 2 * n)
            for x in range(self.w):
                var r, g, bl = Int(a.unsafe_load(x)), Int(a.unsafe_load(x)), Int(a.unsafe_load(x))
                if rgb:
                    g, bl = Int(b.unsafe_load(x)), Int(c.unsafe_load(x))
                elif not grey:
                    var cb, cr = Int(b.unsafe_load(x)) - 128, Int(c.unsafe_load(x)) - 128
                    r += (91881 * cr + 32768) >> 16
                    g += (-22554 * cb - 46802 * cr + 32768) >> 16
                    bl += (116130 * cb + 32768) >> 16
                px[y * self.w + x] = UInt32(clamp8(r)) | UInt32(clamp8(g)) << 8 | UInt32(clamp8(bl)) << 16 | 0xFF000000
        return px^


def jpeg_decode_rgb(d: Span[UInt8, _], mut px: List[UInt8], max_pixels: Int = MAXPX) raises -> Tuple[Int, Int]:
    """As jpeg_decode, but the pixels go to `px` as packed RGB, 3 bytes per pixel (no alpha): 3/4 of the bytes and
    no repack for callers that want RGB rows. Returns (width, height)."""
    var j = Jpeg(d)
    j.maxpx = max_pixels
    j.parse()
    j.idct()
    px = j.rgb()
    return (j.w, j.h)


def jpeg_decode(d: Span[UInt8, _], max_pixels: Int = MAXPX) raises -> Tuple[Int, Int, List[UInt32]]:
    """(width, height, pixels) of a Huffman JPEG, 8-bit, 1 or 3 components. Refuses more than
    `max_pixels` (default 64 M, 256 MB as RGBA) before allocating; raise it for larger photos."""
    var j = Jpeg(d)
    j.maxpx = max_pixels
    j.parse()
    j.idct()
    return (j.w, j.h, j.pixels())
