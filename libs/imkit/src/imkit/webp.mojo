"""Pure Mojo WebP decoder (no FFI, no system library). `webp_decode(bytes)` returns (width, height, pixels), pixels packed
r | g << 8 | b << 16 | a << 24 like png_decode. Lossless VP8L: every transform, color cache, meta prefix codes. Lossy VP8 key frames
and the ALPH chunk are in the sections below. Animation raises. Test oracle: ImageMagick/libwebp (tests/webp_fixtures.sh).
"""

comptime MAXPX = 1 << 26  # the largest picture webp_decode allocates for (same limit as png_decode in assets.mojo)
comptime MAXTAB = 1 << 24  # prefix-code table entries one VP8L image may build (64 MB)


def le16(d: Span[UInt8, _], i: Int) -> Int:
    return Int(d[i]) | Int(d[i + 1]) << 8


def le24(d: Span[UInt8, _], i: Int) -> Int:
    return Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16


def le32(d: Span[UInt8, _], i: Int) -> Int:
    return le24(d, i) | Int(d[i + 3]) << 24


def size_ok(w: Int, h: Int) raises:
    """Checked before any allocation that grows with w * h."""
    if w < 1 or h < 1 or w > MAXPX or h > MAXPX or w * h > MAXPX:
        raise Error("webp: " + String(w) + " x " + String(h) + " is not a picture size (" + String(MAXPX) + " pixels at most)")


# ---------------------------------------------------------------------------------------------------------------------
# VP8L (lossless)
# ---------------------------------------------------------------------------------------------------------------------


struct Bits(Movable):
    """LSB-first bit reader. Reads past the end give zero bits and `over()` turns true."""

    var d: List[UInt8]
    var pos: Int  # next byte to load, counts past the end too
    var val: UInt64
    var nbits: Int

    def __init__(out self, d: Span[UInt8, _]):
        self.d = List[UInt8](d)
        self.pos = 0
        self.val = 0
        self.nbits = 0

    def fill(mut self):
        while self.nbits <= 56:
            var b = UInt64(self.d[self.pos]) if self.pos < len(self.d) else 0
            self.val |= b << UInt64(self.nbits)
            self.pos += 1
            self.nbits += 8

    def bits(mut self, n: Int) -> Int:
        self.fill()
        var v = Int(self.val & ((UInt64(1) << UInt64(n)) - 1))
        self.val >>= UInt64(n)
        self.nbits -= n
        return v

    def over(self) -> Bool:
        return self.pos * 8 - self.nbits > len(self.d) * 8


def build_table(lens: List[Int], mut tab: List[UInt32]) raises -> Int:
    """Append the lookup table of the canonical prefix code with these lengths, entry = len << 16 | symbol. Returns the table
    index width. One used symbol is a zero-bit code; anything else must be a complete code."""
    var cnt = List[Int](length=16, fill=0)
    var used, last = 0, 0
    for s in range(len(lens)):
        if lens[s] > 0:
            cnt[lens[s]] += 1
            used += 1
            last = s
    if used == 0:
        raise Error("webp: empty prefix code")
    if used == 1:
        tab.append(UInt32(last))
        return 0
    var left, maxl = 1, 0
    for l in range(1, 16):
        left = left * 2 - cnt[l]
        if left < 0:
            raise Error("webp: oversubscribed prefix code")
        if cnt[l] > 0:
            maxl = l
    if left != 0:
        raise Error("webp: incomplete prefix code")
    if len(tab) + (1 << maxl) > MAXTAB:
        raise Error("webp: prefix codes too large")
    var next = List[Int](length=17, fill=0)
    var code = 0
    for l in range(1, 16):
        code = (code + cnt[l - 1]) << 1 if l > 1 else 0
        next[l] = code
    var base = len(tab)
    tab.resize(base + (1 << maxl), 0)
    for s in range(len(lens)):
        var l = lens[s]
        if l == 0:
            continue
        var c = next[l]
        next[l] += 1
        var rev = 0  # canonical codes are MSB first, the stream is LSB first
        for k in range(l):
            rev |= ((c >> k) & 1) << (l - 1 - k)
        for k in range(rev, 1 << maxl, 1 << l):
            tab[base + k] = UInt32(l << 16 | s)
    return maxl


struct Codes(Movable):
    """The prefix codes of every meta group: five per group (green + lengths + cache, red, blue, alpha, distance)."""

    var tab: List[UInt32]
    var off: List[Int]
    var nb: List[Int]

    def __init__(out self):
        self.tab = List[UInt32]()
        self.off = List[Int]()
        self.nb = List[Int]()

    def sym(self, mut br: Bits, c: Int) -> Int:
        br.fill()
        var e = self.tab[self.off[c] + Int(br.val & UInt64((1 << self.nb[c]) - 1))]
        var l = Int(e >> 16)
        br.val >>= UInt64(l)
        br.nbits -= l
        return Int(e & 0xFFFF)


def read_code(mut br: Bits, size: Int, mut tab: List[UInt32]) raises -> Int:
    """Read one prefix code of `size` symbols from the stream, append its table, return the index width."""
    var lens = List[Int](length=size, fill=0)
    if br.bits(1) == 1:  # simple: one or two symbols
        var n = br.bits(1) + 1
        var s = br.bits(8 if br.bits(1) == 1 else 1)
        if s >= size:
            raise Error("webp: prefix symbol out of range")
        lens[s] = 1
        if n == 2:
            s = br.bits(8)
            if s >= size:
                raise Error("webp: prefix symbol out of range")
            lens[s] = 1
    else:
        var order: List[Int] = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        var cl = List[Int](length=19, fill=0)
        for i in range(br.bits(4) + 4):
            cl[order[i]] = br.bits(3)
        var ct = List[UInt32]()
        var cb = build_table(cl, ct)
        var maxs = size
        if br.bits(1) == 1:
            maxs = 2 + br.bits(2 + 2 * br.bits(3))
            if maxs > size:
                raise Error("webp: prefix length count too large")
        var s, prev = 0, 8
        while s < size and maxs > 0:
            maxs -= 1
            br.fill()
            var e = ct[Int(br.val & UInt64((1 << cb) - 1))]
            br.val >>= UInt64(Int(e >> 16))
            br.nbits -= Int(e >> 16)
            var c = Int(e & 0xFFFF)
            if c < 16:
                lens[s] = c
                s += 1
                if c != 0:
                    prev = c
            else:
                var rep = br.bits(2) + 3 if c == 16 else (br.bits(3) + 3 if c == 17 else br.bits(7) + 11)
                if s + rep > size:
                    raise Error("webp: prefix length run past the alphabet")
                for _ in range(rep):
                    lens[s] = prev if c == 16 else 0
                    s += 1
    if br.over():
        raise Error("webp: truncated")
    return build_table(lens, tab)


def plane_dist(code: Int, xs: Int) -> Int:
    """Distance code -> pixel distance: codes above 120 are plain, the rest are 2-D neighbourhood offsets."""
    if code > 120:
        return code - 120
    var t: List[Int] = [
        0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1A, 0x26, 0x2A, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1B, 0x36, 0x3A,
        0x25, 0x2B, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1C, 0x35, 0x3B, 0x46, 0x4A, 0x24, 0x2C, 0x58, 0x45, 0x4B, 0x34, 0x3C, 0x03,
        0x57, 0x59, 0x13, 0x1D, 0x56, 0x5A, 0x23, 0x2D, 0x44, 0x4C, 0x55, 0x5B, 0x33, 0x3D, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1E,
        0x66, 0x6A, 0x22, 0x2E, 0x54, 0x5C, 0x43, 0x4D, 0x65, 0x6B, 0x32, 0x3E, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5D, 0x11, 0x1F,
        0x64, 0x6C, 0x42, 0x4E, 0x76, 0x7A, 0x21, 0x2F, 0x75, 0x7B, 0x31, 0x3F, 0x63, 0x6D, 0x52, 0x5E, 0x00, 0x74, 0x7C, 0x41,
        0x4F, 0x10, 0x20, 0x62, 0x6E, 0x30, 0x73, 0x7D, 0x51, 0x5F, 0x40, 0x72, 0x7E, 0x61, 0x6F, 0x50, 0x71, 0x7F, 0x60, 0x70,
    ]
    var v = t[code - 1]
    return max((v >> 4) * xs + 8 - (v & 15), 1)


def lz_value(mut br: Bits, p: Int) -> Int:
    """Length or distance from its prefix symbol plus extra bits."""
    if p < 4:
        return p + 1
    var extra = (p - 2) >> 1
    return ((2 + (p & 1)) << extra) + br.bits(extra) + 1


def cache_key(v: UInt32, bits: Int) -> Int:
    return Int((v * UInt32(0x1E35A7BD)) >> UInt32(32 - bits))


def decode_image(mut br: Bits, w: Int, h: Int, main: Bool) raises -> List[UInt32]:
    """One entropy-coded ARGB image of w x h (the main image, or a transform / meta-group sub-image)."""
    var cbits = 0
    if br.bits(1) == 1:
        cbits = br.bits(4)
        if cbits < 1 or cbits > 11:
            raise Error("webp: color cache bits " + String(cbits))
    var gbits, gw, ngroups = 0, 0, 1
    var egrp = List[UInt32]()
    if main and br.bits(1) == 1:
        gbits = br.bits(3) + 2
        gw = (w + (1 << gbits) - 1) >> gbits
        egrp = decode_image(br, gw, (h + (1 << gbits) - 1) >> gbits, False)
        for i in range(len(egrp)):
            egrp[i] = (egrp[i] >> 8) & 0xFFFF
            ngroups = max(ngroups, Int(egrp[i]) + 1)
    var used = List[Int](length=ngroups, fill=-1)  # group -> slot among the groups the image uses, in stream order
    if ngroups == 1:
        used[0] = 0
    else:
        for i in range(len(egrp)):
            used[Int(egrp[i])] = 0
        var nused = 0
        for g in range(ngroups):
            if used[g] == 0:
                used[g] = nused
                nused += 1
    var cs = Codes()
    var sizes: List[Int] = [256 + 24 + (1 << cbits if cbits > 0 else 0), 256, 256, 256, 40]
    for g in range(ngroups):
        var start = len(cs.tab)
        for k in range(5):
            var o = len(cs.tab)
            var nb = read_code(br, sizes[k], cs.tab)
            if used[g] >= 0:
                cs.off.append(o)
                cs.nb.append(nb)
        if used[g] < 0:
            cs.tab.resize(start, 0)
    var total = w * h
    var px = List[UInt32](length=total, fill=0)
    var cache = List[UInt32](length=(1 << cbits) if cbits > 0 else 0, fill=0)
    var pos, x, y, grp = 0, 0, 0, 0
    while pos < total:
        if br.over():
            raise Error("webp: truncated")
        if gbits > 0:
            grp = used[Int(egrp[(y >> gbits) * gw + (x >> gbits)])]
        var s = cs.sym(br, grp * 5)
        if s < 256:
            var r = cs.sym(br, grp * 5 + 1)
            var b = cs.sym(br, grp * 5 + 2)
            var a = cs.sym(br, grp * 5 + 3)
            var v = UInt32(a) << 24 | UInt32(r) << 16 | UInt32(s) << 8 | UInt32(b)
            px[pos] = v
            if cbits > 0:
                cache[cache_key(v, cbits)] = v
            pos += 1
        elif s < 280:
            var n = lz_value(br, s - 256)
            var dist = plane_dist(lz_value(br, cs.sym(br, grp * 5 + 4)), w)
            if dist > pos or n > total - pos:
                raise Error("webp: backward reference out of range")
            for _ in range(n):
                var v = px[pos - dist]
                px[pos] = v
                if cbits > 0:
                    cache[cache_key(v, cbits)] = v
                pos += 1
        else:
            if s - 280 >= len(cache):
                raise Error("webp: color cache index out of range")
            var v = cache[s - 280]
            px[pos] = v
            cache[cache_key(v, cbits)] = v
            pos += 1
        x = pos % w
        y = pos // w
    if br.over():
        raise Error("webp: truncated")
    return px^


def add4(a: UInt32, b: UInt32) -> UInt32:
    """Per-channel a + b mod 256."""
    return ((a & 0xFF00FF00) + (b & 0xFF00FF00)) & 0xFF00FF00 | ((a & 0x00FF00FF) + (b & 0x00FF00FF)) & 0x00FF00FF


def avg2(a: UInt32, b: UInt32) -> UInt32:
    return (((a ^ b) & 0xFEFEFEFE) >> 1) + (a & b)


def chan(v: UInt32, i: Int) -> Int:
    return Int((v >> UInt32(8 * i)) & 255)


def s8(v: Int) -> Int:
    return v - 256 if v >= 128 else v


def clamp8(v: Int) -> UInt32:
    return UInt32(min(max(v, 0), 255))


def predict(mode: Int, l: UInt32, t: UInt32, tr: UInt32, tl: UInt32) -> UInt32:
    if mode == 1:
        return l
    if mode == 2:
        return t
    if mode == 3:
        return tr
    if mode == 4:
        return tl
    if mode == 5:
        return avg2(avg2(l, tr), t)
    if mode == 6:
        return avg2(l, tl)
    if mode == 7:
        return avg2(l, t)
    if mode == 8:
        return avg2(tl, t)
    if mode == 9:
        return avg2(t, tr)
    if mode == 10:
        return avg2(avg2(l, tl), avg2(t, tr))
    if mode == 11:
        var pl, pt = 0, 0
        for i in range(4):
            var p = chan(l, i) + chan(t, i) - chan(tl, i)
            pl += abs(p - chan(l, i))
            pt += abs(p - chan(t, i))
        return l if pl < pt else t
    if mode == 12:
        var v = UInt32(0)
        for i in range(4):
            v |= clamp8(chan(l, i) + chan(t, i) - chan(tl, i)) << UInt32(8 * i)
        return v
    if mode == 13:
        var a = avg2(l, t)
        var v = UInt32(0)
        for i in range(4):
            var d = chan(a, i) - chan(tl, i)
            v |= clamp8(chan(a, i) + (d // 2 if d >= 0 else -((-d) // 2))) << UInt32(8 * i)
        return v
    return 0xFF000000


struct Xform(Movable):
    var kind: Int  # 0 predictor, 1 cross color, 2 subtract green, 3 color indexing
    var bits: Int
    var xs: Int  # image width this transform sees
    var data: List[UInt32]

    def __init__(out self, kind: Int, bits: Int, xs: Int, var data: List[UInt32]):
        self.kind = kind
        self.bits = bits
        self.xs = xs
        self.data = data^


def inverse(x: Xform, mut px: List[UInt32], w: Int, h: Int) raises -> List[UInt32]:
    """Undo one transform on the w x h picture (w is x.xs, or the final width for color indexing's output)."""
    var out = List[UInt32]()
    if x.kind == 0:
        var bw = (w + (1 << x.bits) - 1) >> x.bits
        for y in range(h):
            for c in range(w):
                var i = y * w + c
                var pred = UInt32(0xFF000000)
                if y == 0:
                    if c > 0:
                        pred = px[i - 1]
                elif c == 0:
                    pred = px[i - w]
                else:
                    var mode = Int(x.data[(y >> x.bits) * bw + (c >> x.bits)] >> 8) & 15
                    pred = predict(mode, px[i - 1], px[i - w], px[i - w + 1], px[i - w - 1])
                px[i] = add4(px[i], pred)
    elif x.kind == 1:
        var bw = (w + (1 << x.bits) - 1) >> x.bits
        for y in range(h):
            for c in range(w):
                var i = y * w + c
                var t = x.data[(y >> x.bits) * bw + (c >> x.bits)]
                var g2r, g2b, r2b = s8(Int(t) & 255), s8(Int(t >> 8) & 255), s8(Int(t >> 16) & 255)
                var v = px[i]
                var g = s8(chan(v, 1))
                var r = (chan(v, 2) + ((g2r * g) >> 5)) & 255
                var b = (chan(v, 0) + ((g2b * g) >> 5) + ((r2b * s8(r)) >> 5)) & 255
                px[i] = (v & 0xFF00FF00) | UInt32(r) << 16 | UInt32(b)
    elif x.kind == 2:
        for i in range(len(px)):
            var v = px[i]
            var g = (v >> 8) & 255
            px[i] = (v & 0xFF00FF00) | ((((v >> 16) & 255) + g) & 255) << 16 | ((v & 255) + g) & 255
    else:
        out = List[UInt32](length=w * h, fill=0)
        var per = 1 << x.bits  # indices per packed pixel
        var bpp = 8 >> x.bits
        var xs = (w + per - 1) >> x.bits
        for y in range(h):
            for c in range(w):
                var packed = Int(px[y * xs + (c >> x.bits)] >> 8) & 255
                var idx = (packed >> ((c & (per - 1)) * bpp)) & ((1 << bpp) - 1)
                out[y * w + c] = x.data[idx] if idx < len(x.data) else 0
    return out^


def vp8l_decode(d: Span[UInt8, _]) raises -> Tuple[Int, Int, List[UInt32]]:
    """Decode a VP8L chunk payload."""
    if len(d) < 5 or d[0] != 0x2F:
        raise Error("webp: not a VP8L stream")
    var br = Bits(d)
    _ = br.bits(8)
    var w = br.bits(14) + 1
    var h = br.bits(14) + 1
    var alpha = br.bits(1)
    if br.bits(3) != 0:
        raise Error("webp: VP8L version is not 0")
    size_ok(w, h)
    var xforms = List[Xform]()
    var seen = 0
    var xs = w
    while br.bits(1) == 1:
        var k = br.bits(2)
        if seen & (1 << k) != 0:
            raise Error("webp: a VP8L transform appears twice")
        seen |= 1 << k
        if k == 0 or k == 1:
            var b = br.bits(3) + 2
            var bw = (xs + (1 << b) - 1) >> b
            xforms.append(Xform(k, b, xs, decode_image(br, bw, (h + (1 << b) - 1) >> b, False)))
        elif k == 2:
            xforms.append(Xform(k, 0, xs, List[UInt32]()))
        else:
            var n = br.bits(8) + 1
            var pal = decode_image(br, n, 1, False)
            for i in range(1, n):
                pal[i] = add4(pal[i], pal[i - 1])
            var b = 3 if n <= 2 else (2 if n <= 4 else (1 if n <= 16 else 0))
            xforms.append(Xform(k, b, xs, pal^))
            xs = (xs + (1 << b) - 1) >> b
    var px = decode_image(br, xs, h, True)
    for i in range(len(xforms) - 1, -1, -1):
        var wd = xforms[i].xs
        var res = inverse(xforms[i], px, wd, h)
        if xforms[i].kind == 3:
            px = res^
    for i in range(len(px)):  # ARGB -> r | g << 8 | b << 16 | a << 24
        var v = px[i]
        px[i] = ((v >> 16) & 255) | (v & 0xFF00) | (v & 255) << 16 | (v & 0xFF000000 if alpha == 1 else 0xFF000000)
    return (w, h, px^)


# ---------------------------------------------------------------------------------------------------------------------
# container
# ---------------------------------------------------------------------------------------------------------------------


def webp_decode(d: Span[UInt8, _]) raises -> Tuple[Int, Int, List[UInt32]]:
    """(width, height, pixels) of a still WebP: simple lossless, simple lossy, or extended (VP8X) with ALPH."""
    if len(d) < 20 or le32(d, 0) != 0x46464952 or le32(d, 8) != 0x50424557:  # "RIFF" .... "WEBP"
        raise Error("webp: not a WebP file")
    var end = le32(d, 4) + 8
    if end > len(d):
        raise Error("webp: truncated file")
    var pos = 12
    while pos + 8 <= end:
        var t = le32(d, pos)
        var n = le32(d, pos + 4)
        if pos + 8 + n > end:
            raise Error("webp: truncated chunk")
        var body = d[pos + 8 : pos + 8 + n]
        if t == 0x4C385056:  # "VP8L"
            return vp8l_decode(body)
        if t == 0x58385056:  # "VP8X"
            if n < 10:
                raise Error("webp: VP8X chunk is too short")
            if body[0] & 2 != 0:
                raise Error("webp: animation is not supported")
        elif t == 0x20385056:  # "VP8 "
            raise Error("webp: lossy VP8 is not implemented yet")
        elif t == 0x4D494E41 or t == 0x464D4E41:  # "ANIM", "ANMF"
            raise Error("webp: animation is not supported")
        pos += 8 + n + (n & 1)
    raise Error("webp: no image data")
