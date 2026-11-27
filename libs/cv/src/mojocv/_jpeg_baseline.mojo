"""Baseline sequential Huffman JPEG reader for stock images."""
from std.bit import byte_swap
from std.builtin.globals import global_constant
from std.os import SEEK_END
from std.math import clamp
from mojocv.mat import Mat
from ._jpeg_pixels import _BytePtr, _I8, _render_row, _upsample, _write_block, _write_dc

comptime _Source = Pointer[UInt8, ImmUntrackedOrigin]
comptime _LOOK = 10
comptime _TABLE = 1 << _LOOK
comptime _MAX_PIXELS = 1 << 26
comptime _ZIGZAG = SIMD[DType.uint8, 64](
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
)


@fieldwise_init
struct _Bits(TrivialRegisterPassable):
    var data: _Source
    var size: Int
    var pos: Int
    var buf: UInt64
    var count: Int

    def refill(mut self):
        """Append bytes, leaving the next unstuffed marker for the marker reader."""
        var p = self.pos
        var n = self.count
        if p + 4 <= self.size:
            var word = self.data.unsafe_offset(p).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()
            var inv = ~word
            if ((inv - 0x01010101) & word & 0x80808080) == 0:
                self.buf |= UInt64(byte_swap(word)) << UInt64(32 - n)
                self.pos = p + 4
                self.count = n + 32
                return
        var buf = self.buf
        while n < 32 and p < self.size:
            var b = self.data[unsafe_offset=p]
            if b == 255:
                if p + 1 == self.size or self.data[unsafe_offset=p + 1] != 0:
                    break
                p += 1
            buf |= UInt64(b) << UInt64(56 - n)
            p += 1
            n += 8
        self.pos, self.count, self.buf = p, n, buf

    @always_inline
    def drop(mut self, n: Int) raises:
        if n > self.count:
            raise Error("jpeg: truncated entropy data")
        self.count -= n
        self.buf <<= UInt64(n)

    @always_inline
    def magnitude(mut self, n: Int) raises -> Int32:
        if n == 0:
            return 0
        if self.count < n:
            self.refill()
        var v = Int32(self.buf >> UInt64(64 - n))
        self.drop(n)
        return _extend(v, n)


@always_inline
def _extend(v: Int32, n: Int) -> Int32:
    return v if v >= Int32(1 << (n - 1)) else v + 1 - Int32(1 << n)


@fieldwise_init
struct _Component(TrivialRegisterPassable):
    var id: Int
    var h: Int
    var v: Int
    var q: Int
    var offset: Int
    var stride: Int
    var width: Int
    var height: Int


comptime _Lookup = Pointer[Int32, MutAnyOrigin]
comptime _Quant = Pointer[UInt8, MutAnyOrigin]


struct _Decoder(Movable):
    var data: _Source
    var size: Int
    var pos: Int
    var width: Int
    var height: Int
    var nf: Int
    var h: Int
    var v: Int
    var restart: Int
    var adobe: Int
    var jfif: Bool
    var components: Array[_Component, 3]
    var quant: List[UInt8]
    var quant_set: Int
    var huff_set: Int
    var lookup: List[Int32]
    var limits: Array[Int32, 8 * 17]
    var first: Array[Int32, 8 * 17]
    var base: Array[Int32, 8 * 17]
    var symbols: Array[UInt8, 8 * 256]
    var scanned: Int
    var plane_bytes: Int
    var planes: List[UInt8]

    def __init__(out self, d: _Source, size: Int):
        self.data, self.size, self.pos = d, size, 2
        self.width, self.height, self.nf, self.h, self.v = 0, 0, 0, 1, 1
        self.restart, self.adobe, self.jfif = 0, -1, False
        self.components = Array[_Component, 3](fill=_Component(0, 0, 0, 0, 0, 0, 0, 0))
        self.quant = List[UInt8](length=4 * 64, fill=0)
        self.quant_set, self.huff_set = 0, 0
        self.lookup = List[Int32](length=8 * _TABLE, fill=0)
        self.limits = Array[Int32, 8 * 17](fill=-1)
        self.first = Array[Int32, 8 * 17](fill=0)
        self.base = Array[Int32, 8 * 17](fill=0)
        self.symbols = Array[UInt8, 8 * 256](uninitialized=True)
        self.scanned, self.plane_bytes = 0, 0
        self.planes = List[UInt8]()

    def be16(self, p: Int) -> Int:
        return Int(self.data[unsafe_offset=p]) << 8 | Int(self.data[unsafe_offset=p + 1])

    def marker(mut self) raises -> Int:
        if self.pos >= self.size or self.data[unsafe_offset=self.pos] != 0xFF:
            raise Error("jpeg: expected marker")
        while self.pos < self.size and self.data[unsafe_offset=self.pos] == 0xFF:
            self.pos += 1
        if self.pos == self.size:
            raise Error("jpeg: truncated marker")
        var m = Int(self.data[unsafe_offset=self.pos])
        self.pos += 1
        if m == 0:
            raise Error("jpeg: stuffed byte outside entropy data")
        return m

    def dqt(mut self, var p: Int, end: Int) raises:
        while p < end:
            var q = Int(self.data[unsafe_offset=p])
            p += 1
            if q >= 16:
                raise Error("unsupported: JPEG quantization precision")
            if q > 3 or p + 64 > end:
                raise Error("jpeg: bad quantization table")
            for k in range(64):
                var v = self.data[unsafe_offset=p + k]
                if v == 0:
                    raise Error("jpeg: zero quantizer")
                self.quant[q * 64 + k] = v
            self.quant_set |= 1 << q
            p += 64

    def dht(mut self, var p: Int, end: Int) raises:
        while p < end:
            if end - p < 17:
                raise Error("jpeg: short Huffman table")
            var spec = Int(self.data[unsafe_offset=p])
            var kind, id = spec >> 4, spec & 15
            if kind > 1 or id > 3:
                raise Error("jpeg: bad Huffman table id")
            var table = kind * 4 + id
            var lengths = table * 17
            var fast = self.lookup.unsafe_ptr().unsafe_offset(table * _TABLE)
            for i in range(_TABLE):
                fast[unsafe_offset=i] = 0
            var code, value = 0, 0
            for length in range(1, 17):
                var n = Int(self.data[unsafe_offset=p + length])
                if code + n >= (1 << length) or value + n > 256 or p + 17 + value + n > end:
                    raise Error("jpeg: invalid Huffman counts")
                self.first[lengths + length] = Int32(code)
                self.limits[lengths + length] = Int32(code + n - 1)
                self.base[lengths + length] = Int32(value - code)
                for i in range(n):
                    var sym = self.data[unsafe_offset=p + 17 + value + i]
                    var mag = Int(sym) if kind == 0 else Int(sym) & 15
                    if (kind == 0 and mag > 11) or (kind == 1 and (mag > 10 or (mag == 0 and sym != 0 and sym != 0xF0))):
                        raise Error("jpeg: invalid baseline Huffman symbol")
                    self.symbols[table * 256 + value + i] = sym
                    if length <= _LOOK:
                        var low = (code + i) << (_LOOK - length)
                        var high = low + (1 << (_LOOK - length))
                        var entry = Int32(Int(sym) << 5)
                        if mag > 0 and length + mag <= _LOOK:
                            var remaining = _LOOK - length - mag
                            for j in range(low, high):
                                var v = Int32((j >> remaining) & ((1 << mag) - 1))
                                fast[unsafe_offset=j] = (_extend(v, mag) << 14) | (1 << 13) | entry | Int32(length + mag)
                        else:
                            for j in range(low, high):
                                fast[unsafe_offset=j] = entry | Int32(length)
                code = (code + n) << 1
                value += n
            if value == 0:
                raise Error("jpeg: empty Huffman table")
            self.huff_set |= 1 << table
            p += 17 + value

    def frame(mut self, p: Int, end: Int) raises:
        if end - p < 6 or self.nf != 0:
            raise Error("jpeg: invalid frame")
        if self.data[unsafe_offset=p] != 8:
            raise Error("unsupported: JPEG sample precision")
        var height, width = self.be16(p + 1), self.be16(p + 3)
        var nf = Int(self.data[unsafe_offset=p + 5])
        if end - p != 6 + 3 * nf or width == 0 or height == 0:
            raise Error("jpeg: invalid frame dimensions or length")
        if nf != 1 and nf != 3:
            raise Error("unsupported: JPEG component count")
        if width * height > _MAX_PIXELS:
            raise Error("unsupported: JPEG exceeds pixel limit")
        self.width, self.height, self.nf = width, height, nf
        var factors = Int(self.data[unsafe_offset=p + 7])
        if nf == 3:
            if factors != 0x11 and factors != 0x21 and factors != 0x22:
                raise Error("unsupported: JPEG luma sampling")
            self.h, self.v = factors >> 4, factors & 15
        var mcux = (width + 8 * self.h - 1) // (8 * self.h)
        var mcuy = (height + 8 * self.v - 1) // (8 * self.v)
        for i in range(nf):
            var q = p + 6 + 3 * i
            var id = Int(self.data[unsafe_offset=q])
            var samp = Int(self.data[unsafe_offset=q + 1])
            var tq = Int(self.data[unsafe_offset=q + 2])
            if tq > 3 or samp >> 4 not in [1, 2, 3, 4] or samp & 15 not in [1, 2, 3, 4]:
                raise Error("jpeg: invalid component")
            if i > 0 and samp != 0x11:
                raise Error("unsupported: JPEG chroma sampling")
            for j in range(i):
                if self.components[j].id == id:
                    raise Error("jpeg: duplicate component id")
            var h, v = (self.h, self.v) if i == 0 else (1, 1)
            var stride = mcux * h * 8
            var cw = (width * h + self.h - 1) // self.h
            var ch = (height * v + self.v - 1) // self.v
            self.components[i] = _Component(id, h, v, tq, self.plane_bytes, stride, cw, ch)
            self.plane_bytes += stride * mcuy * v * 8

    @no_inline
    def _long_symbol(self, mut bits: _Bits, table: Int) raises -> Int32:
        var row = table * 17
        var code = Int32(bits.buf >> UInt64(64 - _LOOK))
        for length in range(_LOOK + 1, 17):
            code = (code << 1) | Int32((bits.buf >> UInt64(64 - length)) & 1)
            if code >= self.first[row + length] and code <= self.limits[row + length]:
                bits.drop(length)
                return Int32(self.symbols[table * 256 + Int(self.base[row + length] + code)])
        raise Error("jpeg: invalid Huffman code")

    @always_inline
    def _entry(self, mut bits: _Bits, fast: _Lookup, table: Int) raises -> Int32:
        if bits.count < 16:
            bits.refill()
        var e = fast[unsafe_offset=Int(bits.buf >> UInt64(64 - _LOOK))]
        if e != 0:
            bits.drop(Int(e & 31))
            return e
        return self._long_symbol(bits, table) << 5

    @always_inline
    def _block(self, mut bits: _Bits, dc: _Lookup, ac: _Lookup, td: Int, ta: Int,
               q: _Quant, mut pred: Int32, dst: _BytePtr, stride: Int) raises:
        var e = self._entry(bits, dc, td)
        pred += (e >> 14) if e & (1 << 13) else bits.magnitude(Int((e >> 5) & 255))
        if pred < -2048 or pred > 2047:
            raise Error("jpeg: DC predictor out of range")
        var base = pred * Int32(q[unsafe_offset=0])
        e = self._entry(bits, ac, ta)
        if e >> 5 == 0:
            _write_dc(base, dst, stride)
            return
        var coeff = Array[_I8, 8](fill=_I8(0))
        var raw = Pointer(to=coeff[0]).unsafe_bitcast[Int32]()
        raw[unsafe_offset=0] = base
        var zz = Pointer(to=global_constant[_ZIGZAG]()).unsafe_bitcast[UInt8]()
        var k = 1
        while k < 64:
            var symbol = Int((e >> 5) & 255)
            if symbol == 0:
                break
            if symbol == 0xF0:
                k += 16
                if k > 64:
                    raise Error("jpeg: zero run exceeds block")
            else:
                k += symbol >> 4
                if k >= 64:
                    raise Error("jpeg: coefficient outside block")
                var value = (e >> 14) if e & (1 << 13) else bits.magnitude(symbol & 15)
                raw[unsafe_offset=Int(zz[unsafe_offset=k])] = value * Int32(q[unsafe_offset=k])
                k += 1
            if k < 64:
                e = self._entry(bits, ac, ta)
        _write_block(coeff, dst, stride)

    def scan(mut self, p: Int, end: Int) raises:
        if p == end or self.nf == 0:
            raise Error("jpeg: scan without a frame")
        var ns = Int(self.data[unsafe_offset=p])
        if ns < 1 or ns > self.nf or end - p != 4 + 2 * ns:
            raise Error("jpeg: invalid scan length")
        if self.data[unsafe_offset=end - 3] != 0 or self.data[unsafe_offset=end - 2] != 63 or self.data[unsafe_offset=end - 1] != 0:
            raise Error("unsupported: JPEG scan parameters")
        var indices = Array[Int, 3](fill=0)
        var dcs = Array[Int, 3](fill=0)
        var acs = Array[Int, 3](fill=0)
        for i in range(ns):
            var id = Int(self.data[unsafe_offset=p + 1 + 2*i])
            var c = 0
            while c < self.nf and self.components[c].id != id:
                c += 1
            if c == self.nf or self.scanned & (1 << c):
                raise Error("jpeg: unknown or repeated scan component")
            var ht = Int(self.data[unsafe_offset=p + 2 + 2*i])
            var dc, ac = ht >> 4, 4 + (ht & 15)
            if dc > 3 or ac > 7 or not (self.huff_set & (1 << dc) and self.huff_set & (1 << ac)):
                raise Error("jpeg: missing Huffman table")
            if not self.quant_set & (1 << self.components[c].q):
                raise Error("jpeg: missing quantization table")
            self.scanned |= 1 << c
            indices[i], dcs[i], acs[i] = c, dc, ac
        if not len(self.planes):
            self.planes = List[UInt8](unsafe_uninit_length=self.plane_bytes)
        var mx = (self.width + 8 * self.h - 1) // (8 * self.h)
        var my = (self.height + 8 * self.v - 1) // (8 * self.v)
        if ns == 1:
            var c = self.components[indices[0]]
            mx, my = (c.width + 7) // 8, (c.height + 7) // 8
        var bits = _Bits(self.data, self.size, self.pos, 0, 0)
        var predictors = Array[Int32, 3](fill=0)
        var remaining = self.restart if self.restart else mx * my
        var next_rst = 0
        var samples = _BytePtr(unsafe_from_address=Int(self.planes.unsafe_ptr()))
        var lut = _Lookup(unsafe_from_address=Int(self.lookup.unsafe_ptr()))
        var quants = _Quant(unsafe_from_address=Int(self.quant.unsafe_ptr()))
        for y in range(my):
            for x in range(mx):
                if remaining == 0:
                    self.pos = bits.pos
                    if bits.count > 7 or self.marker() != 0xD0 + next_rst:
                        raise Error("jpeg: wrong restart marker")
                    bits = _Bits(self.data, self.size, self.pos, 0, 0)
                    next_rst = (next_rst + 1) & 7
                    remaining = self.restart
                    predictors = Array[Int32, 3](fill=0)
                remaining -= 1
                for i in range(ns):
                    var c = self.components[indices[i]]
                    var h, v = (1, 1) if ns == 1 else (c.h, c.v)
                    var td, ta = dcs[i], acs[i]
                    var dc = lut.unsafe_offset(td * _TABLE)
                    var ac = lut.unsafe_offset(ta * _TABLE)
                    var q = quants.unsafe_offset(c.q * 64)
                    var dst = samples.unsafe_offset(c.offset + 8 * (y * v * c.stride + x * h))
                    for by in range(v):
                        for bx in range(h):
                            self._block(bits, dc, ac, td, ta, q, predictors[i],
                                        dst.unsafe_offset(8 * (by * c.stride + bx)), c.stride)
        if bits.count > 7:
            raise Error("jpeg: excess entropy data")
        self.pos = bits.pos

    def _starts(self, p: Int, end: Int, sig: StringSlice) -> Bool:
        var bytes = sig.as_bytes()
        if end - p < len(bytes):
            return False
        for i in range(len(bytes)):
            if self.data[unsafe_offset=p + i] != bytes[i]:
                return False
        return True

    def _exif(self, start: Int, end: Int) raises:
        var t = start + 6
        if end - t < 8:
            raise Error("unsupported: JPEG EXIF header")
        var order = self.be16(t)
        if order != 0x4949 and order != 0x4D4D:
            raise Error("unsupported: JPEG EXIF byte order")
        var d = self.data
        def read(p: Int, n: Int) {imm order, imm d} -> Int:
            var x = 0
            for i in range(n):
                var b = p + (i if order == 0x4D4D else n - 1 - i)
                x = (x << 8) | Int(d[unsafe_offset=b])
            return x
        var ifd = t + read(t + 4, 4)
        if read(t + 2, 2) != 42 or ifd < t + 8 or ifd + 2 > end:
            raise Error("unsupported: JPEG EXIF directory")
        var entries = read(ifd, 2)
        if ifd + 2 + entries * 12 > end:
            raise Error("unsupported: JPEG EXIF entries")
        for i in range(entries):
            var p = ifd + 2 + 12 * i
            if read(p, 2) == 0x0112:
                if read(p + 2, 2) != 3 or read(p + 4, 4) != 1 or read(p + 8, 2) != 1:
                    raise Error("unsupported: JPEG EXIF orientation")
                return

    def _icc(self, start: Int, end: Int) raises:
        # Match the stock loader's sRGB profile description check, including UTF-16 strings.
        if end - start >= 14 and self.be16(start + 12) == 0x0101:
            comptime name = SIMD[DType.uint8, 4](0x73, 0x72, 0x67, 0x62)
            var matched = 0
            for p in range(start + 14, end):
                var b = self.data[unsafe_offset=p]
                if b == 0:
                    continue
                b |= 0x20
                matched = matched + 1 if b == name[matched] else Int(b == name[0])
                if matched == 4:
                    return
        raise Error("unsupported: JPEG ICC profile")

    def parse(mut self) raises:
        if self.size < 4 or self.be16(0) != 0xFFD8:
            raise Error("jpeg: invalid SOI")
        while True:
            var m = self.marker()
            if m == 0xD9:
                if self.nf == 0 or self.scanned != (1 << self.nf) - 1:
                    raise Error("jpeg: incomplete image")
                return
            if m == 0xD8 or 0xD0 <= m <= 0xD7 or m == 1:
                raise Error("jpeg: unexpected stand-alone marker")
            if self.pos + 2 > self.size:
                raise Error("jpeg: truncated segment size")
            var start = self.pos + 2
            var end = self.pos + self.be16(self.pos)
            if end < start or end > self.size:
                raise Error("jpeg: truncated segment")
            self.pos = end
            if m == 0xC0:
                self.frame(start, end)
            elif m == 0xC4:
                self.dht(start, end)
            elif 0xC0 <= m <= 0xCF or m == 0xDC or m == 0xDE or m == 0xDF:
                raise Error("unsupported: JPEG coding process")
            elif m == 0xDB:
                self.dqt(start, end)
            elif m == 0xDD:
                if end - start != 2:
                    raise Error("jpeg: invalid restart interval")
                self.restart = self.be16(start)
            elif m == 0xDA:
                self.scan(start, end)
            elif m == 0xE0 and self._starts(start, end, "JFIF\0"):
                self.jfif = True
            elif m == 0xE1 and self._starts(start, end, "Exif\0\0"):
                self._exif(start, end)
            elif m == 0xE2 and self._starts(start, end, "ICC_PROFILE\0"):
                self._icc(start, end)
            elif m == 0xEE and end - start >= 12 and self._starts(start, end, "Adobe"):
                self.adobe = Int(self.data[unsafe_offset=start + 11])
                if self.adobe > 1:
                    raise Error("unsupported: JPEG Adobe color transform")
            elif not (0xE0 <= m <= 0xEF or m == 0xFE):
                raise Error("unsupported: JPEG marker")

    def render(self) raises -> Mat[DType.uint8]:
        var y = self.components[0]
        var u = self.components[1]
        var v = self.components[2]
        var rgb = not self.jfif and (self.adobe == 0 or (self.adobe < 0 and y.id == 82 and u.id == 71 and v.id == 66))
        if rgb and self.h != 1:
            raise Error("unsupported: subsampled RGB JPEG")
        var output = Mat[DType.uint8](self.height, self.width, 3, False)
        var dst = output.ptr()
        var src = _BytePtr(unsafe_from_address=Int(self.planes.unsafe_ptr()))
        var scratch = List[UInt8](unsafe_uninit_length=2 * (self.width + 1) if self.h > 1 else 0)
        var su = _BytePtr(unsafe_from_address=Int(scratch.unsafe_ptr()))
        var sv = su.unsafe_offset(self.width + 1) if self.h > 1 else su
        for row in range(self.height):
            var d = dst.unsafe_offset(row * self.width * 3)
            var l = src.unsafe_offset(row * y.stride)
            if self.nf == 1:
                _render_row[1](d, l, l, l, self.width)
                continue
            var cy = row // self.v
            var up = src.unsafe_offset(u.offset + cy * u.stride)
            var vp = src.unsafe_offset(v.offset + cy * v.stride)
            if self.h > 1:
                var neighbor = clamp(cy + (1 if row & 1 else -1), 0, u.height - 1)
                var du = (neighbor - cy) * u.stride
                var dv = (neighbor - cy) * v.stride
                _upsample(up, up.unsafe_offset(du), su, u.width, self.v == 2)
                _upsample(vp, vp.unsafe_offset(dv), sv, v.width, self.v == 2)
                up, vp = su, sv
            if rgb:
                _render_row[2](d, l, up, vp, self.width)
            else:
                _render_row[0](d, l, up, vp, self.width)
        _ = len(scratch)
        return output^


def decode_baseline_jpeg(bytes: List[UInt8]) raises -> Mat[DType.uint8]:
    """Decode BGR pixels. Errors prefixed with `unsupported:` mark other JPEG variants."""
    var data = bytes.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
    var decoder = _Decoder(data, len(bytes))
    decoder.parse()
    _ = len(bytes)
    return decoder.render()


def load_baseline_jpeg(path: String) raises -> Mat[DType.uint8]:
    var f = open(path, "r")
    var size = Int(f.seek(0, SEEK_END))
    _ = f.seek(0)
    return decode_baseline_jpeg(f.read_bytes(size))
