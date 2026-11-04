# TrueType reader: a port of the parts of OpenCV 5.0.0's stb_truetype fork (modules/imgproc/src/stb_truetype.cpp, public
# domain / MIT) that cv2.putText reaches: cmap (formats 0, 4, 6, 12), head/hhea/hmtx, loca/glyf with composite glyphs, and
# the glyph outline as stbtt vertices. Variable-font deltas live in the same struct (see `_vary`). Integer and float32
# arithmetic follow the C source line by line: pixel parity with cv2 depends on it, not on fontTools' float semantics.
from std.math import sqrt

comptime VMOVE = 1
comptime VLINE = 2
comptime VCURVE = 3


def _i16(v: Int) -> Int:
    return ((v + 32768) & 65535) - 32768


@fieldwise_init
struct Vertex(Copyable, Movable):
    var kind: Int
    var x: Int
    var y: Int
    var cx: Int
    var cy: Int


@fieldwise_init
struct Shape(Movable):
    var v: List[Vertex]
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int


struct Font(Movable):
    var d: List[UInt8]
    var head: Int
    var hhea: Int
    var hmtx: Int
    var loca: Int
    var glyf: Int
    var index_map: Int
    var num_glyphs: Int
    var loc_format: Int
    var avar: Int
    var gvar: Int
    var axis_count: Int
    var ax_tag: List[Int]
    var ax_min: List[Int]
    var ax_def: List[Int]
    var ax_cur: List[Int]
    var ax_max: List[Int]
    var norm: List[Int]
    var gv_shared_count: Int
    var gv_shared: Int
    var gv_glob: Int
    var gv_offs: Int
    var gv_fmt: Int

    def __init__(out self, var data: List[UInt8]) raises:
        self.d = data^
        self.head = _find_table(self.d, "head")
        self.hhea = _find_table(self.d, "hhea")
        self.hmtx = _find_table(self.d, "hmtx")
        self.loca = _find_table(self.d, "loca")
        self.glyf = _find_table(self.d, "glyf")
        self.avar = _find_table(self.d, "avar")
        self.gvar = _find_table(self.d, "gvar")
        self.index_map = 0
        self.num_glyphs = 0xFFFF
        self.loc_format = 0
        self.axis_count = 0
        self.ax_tag = List[Int]()
        self.ax_min = List[Int]()
        self.ax_def = List[Int]()
        self.ax_cur = List[Int]()
        self.ax_max = List[Int]()
        self.norm = List[Int]()
        self.gv_shared_count = 0
        self.gv_shared = 0
        self.gv_glob = 0
        self.gv_offs = 0
        self.gv_fmt = 0
        var cmap = _find_table(self.d, "cmap")
        var fvar = _find_table(self.d, "fvar")
        var hvar = _find_table(self.d, "HVAR")
        var maxp = _find_table(self.d, "maxp")
        if cmap == 0 or self.head == 0 or self.hhea == 0 or self.hmtx == 0 or self.glyf == 0 or self.loca == 0:
            raise Error("font: missing required table (cmap/head/hhea/hmtx/loca/glyf)")
        if maxp != 0:
            self.num_glyphs = self.u16(maxp + 4)
        for i in range(self.u16(cmap + 2)):
            var rec = cmap + 4 + 8 * i
            var plat = self.u16(rec)
            if plat == 0 or (plat == 3 and (self.u16(rec + 2) == 1 or self.u16(rec + 2) == 10)):
                self.index_map = cmap + self.u32(rec + 4)  # the last matching record wins, as in stbtt
        if self.index_map == 0:
            raise Error("font: no unicode cmap subtable")
        self.loc_format = self.u16(self.head + 50)
        if fvar != 0 or self.gvar != 0 or hvar != 0:
            if fvar == 0 or self.gvar == 0 or hvar == 0:
                raise Error("font: variable font needs fvar, gvar and HVAR")
            self._read_fvar(fvar)
            self._read_gvar()
            self.set_instance(-1, 0)

    @always_inline
    def u8(self, o: Int) -> Int:
        return Int(self.d[o]) if o >= 0 and o < len(self.d) else 0

    @always_inline
    def u16(self, o: Int) -> Int:
        return self.u8(o) * 256 + self.u8(o + 1)

    @always_inline
    def i16(self, o: Int) -> Int:
        var v = self.u16(o)
        return v - 65536 if v >= 32768 else v

    @always_inline
    def u32(self, o: Int) -> Int:
        return self.u16(o) * 65536 + self.u16(o + 2)

    @always_inline
    def i32(self, o: Int) -> Int:
        var v = self.u32(o)
        return v - 4294967296 if v >= 2147483648 else v

    def glyph_index(self, cp: Int) -> Int:
        var m = self.index_map
        var fmt = self.u16(m)
        if fmt == 0:
            return self.u8(m + 6 + cp) if cp < self.u16(m + 2) - 6 else 0
        if fmt == 6:
            var first = self.u16(m + 6)
            return self.u16(m + 10 + (cp - first) * 2) if cp >= first and cp < first + self.u16(m + 8) else 0
        if fmt == 4:
            if cp > 0xFFFF:
                return 0
            var segcount = self.u16(m + 6) >> 1
            var search_range = self.u16(m + 8) >> 1
            var entry_selector = self.u16(m + 10)
            var range_shift = self.u16(m + 12) >> 1
            var end_count = m + 14
            var search = end_count
            if cp >= self.u16(search + range_shift * 2):
                search += range_shift * 2
            search -= 2
            while entry_selector != 0:
                search_range >>= 1
                if cp > self.u16(search + search_range * 2):
                    search += search_range * 2
                entry_selector -= 1
            search += 2
            var item = (search - end_count) >> 1
            var start = self.u16(m + 14 + segcount * 2 + 2 + 2 * item)
            if cp < start:
                return 0
            var offset = self.u16(m + 14 + segcount * 6 + 2 + 2 * item)
            if offset == 0:
                return (cp + self.i16(m + 14 + segcount * 4 + 2 + 2 * item)) & 0xFFFF
            return self.u16(offset + (cp - start) * 2 + m + 14 + segcount * 6 + 2 + 2 * item)
        if fmt == 12 or fmt == 13:
            var low = 0
            var high = self.u32(m + 12)
            while low < high:
                var mid = low + ((high - low) >> 1)
                var s = self.u32(m + 16 + mid * 12)
                var e = self.u32(m + 16 + mid * 12 + 4)
                if cp < s:
                    high = mid
                elif cp > e:
                    low = mid + 1
                else:
                    var sg = self.u32(m + 16 + mid * 12 + 8)
                    return sg + cp - s if fmt == 12 else sg
        return 0

    def hmetrics(self, gid: Int) -> Tuple[Int, Int]:
        """(advanceWidth, leftSideBearing) from hmtx, always the default instance (stbtt never applies HVAR)."""
        var n = self.u16(self.hhea + 34)
        if gid < n:
            return (self.i16(self.hmtx + 4 * gid), self.i16(self.hmtx + 4 * gid + 2))
        return (self.i16(self.hmtx + 4 * (n - 1)), self.i16(self.hmtx + 4 * n + 2 * (gid - n)))

    def vmetrics(self) -> Tuple[Int, Int, Int]:
        """(ascent, descent, lineGap) from hhea."""
        return (self.i16(self.hhea + 4), self.i16(self.hhea + 6), self.i16(self.hhea + 8))

    def scale_for_pixel_height_nodesc(self, height: Float32) -> Float32:
        return height / Float32(self.i16(self.hhea + 4))

    def glyf_offset(self, gid: Int) -> Int:
        """Offset of the glyph in `glyf`, or -1 when it is empty or out of range."""
        if gid >= self.num_glyphs or self.loc_format >= 2:
            return -1
        var g1: Int
        var g2: Int
        if self.loc_format == 0:
            g1 = self.glyf + self.u16(self.loca + gid * 2) * 2
            g2 = self.glyf + self.u16(self.loca + gid * 2 + 2) * 2
        else:
            g1 = self.glyf + self.u32(self.loca + gid * 4)
            g2 = self.glyf + self.u32(self.loca + gid * 4 + 4)
        return -1 if g1 == g2 else g1

    def glyph_box(self, gid: Int) -> Optional[Tuple[Int, Int, Int, Int]]:
        var g = self.glyf_offset(gid)
        if g < 0:
            return None
        return (self.i16(g + 2), self.i16(g + 4), self.i16(g + 6), self.i16(g + 8))

    def glyph_shape(self, gid: Int) -> Shape:
        """stbtt_GetGlyphShape for TrueType outlines: vertices in font units plus the (variation-adjusted) bbox."""
        var out = Shape(List[Vertex](), 0, 0, 0, 0)
        var g = self.glyf_offset(gid)
        if g < 0:
            return out^
        var ncont = self.i16(g)
        if ncont > 0:
            self._simple(g, gid, ncont, out)
        elif ncont < 0:
            self._composite(g, gid, out)
        return out^

    def _simple(self, g: Int, gid: Int, ncont: Int, mut out: Shape):
        var end_pts = g + 10
        var ins = self.u16(g + 10 + ncont * 2)
        var p = g + 10 + ncont * 2 + 2 + ins
        out.x0 = self.i16(g + 2)
        out.y0 = self.i16(g + 4)
        out.x1 = self.i16(g + 6)
        out.y1 = self.i16(g + 8)
        var n = 1 + self.u16(end_pts + ncont * 2 - 2)
        var fl = List[Int](length=n, fill=0)
        var px = List[Int](length=n, fill=0)
        var py = List[Int](length=n, fill=0)
        var flags = 0
        var flagcount = 0
        for i in range(n):
            if flagcount == 0:
                flags = self.u8(p)
                p += 1
                if flags & 8:
                    flagcount = self.u8(p)
                    p += 1
            else:
                flagcount -= 1
            fl[i] = flags
        var x = 0
        for i in range(n):
            var f = fl[i]
            if f & 2:
                var dx = self.u8(p)
                p += 1
                x += dx if (f & 16) else -dx
            elif not (f & 16):
                x += self.i16(p)
                p += 2
            px[i] = _i16(x)
        var y = 0
        for i in range(n):
            var f = fl[i]
            if f & 4:
                var dy = self.u8(p)
                p += 1
                y += dy if (f & 32) else -dy
            elif not (f & 32):
                y += self.i16(p)
                p += 2
            py[i] = _i16(y)
        self._vary(gid, False, ncont, end_pts, px, py, n, out)
        var next_move = 0
        var j = 0
        var was_off = False
        var start_off = False
        var sx = 0
        var sy = 0
        var cx = 0
        var cy = 0
        var scx = 0
        var scy = 0
        var i = 0
        while i < n:
            var f = fl[i]
            var vx = px[i]
            var vy = py[i]
            if next_move == i:
                if i != 0:
                    _close_shape(out.v, was_off, start_off, sx, sy, scx, scy, cx, cy)
                start_off = (f & 1) == 0
                if start_off:
                    scx = vx
                    scy = vy
                    if (fl[i + 1] & 1) == 0:
                        sx = (vx + px[i + 1]) >> 1
                        sy = (vy + py[i + 1]) >> 1
                    else:
                        sx = px[i + 1]
                        sy = py[i + 1]
                        i += 1
                else:
                    sx = vx
                    sy = vy
                out.v.append(Vertex(VMOVE, _i16(sx), _i16(sy), 0, 0))
                was_off = False
                next_move = 1 + self.u16(end_pts + j * 2)
                j += 1
            elif (f & 1) == 0:
                if was_off:
                    out.v.append(Vertex(VCURVE, _i16((cx + vx) >> 1), _i16((cy + vy) >> 1), _i16(cx), _i16(cy)))
                cx = vx
                cy = vy
                was_off = True
            else:
                if was_off:
                    out.v.append(Vertex(VCURVE, vx, vy, _i16(cx), _i16(cy)))
                else:
                    out.v.append(Vertex(VLINE, vx, vy, 0, 0))
                was_off = False
            i += 1
        _close_shape(out.v, was_off, start_off, sx, sy, scx, scy, cx, cy)

    def _composite(self, g: Int, gid: Int, mut out: Shape):
        var comp = g + 10
        var more = True
        out.x0 = self.i16(g + 2)
        out.y0 = self.i16(g + 4)
        out.x1 = self.i16(g + 6)
        out.y1 = self.i16(g + 8)
        var ofs_x = List[Int](length=32, fill=0)
        var ofs_y = List[Int](length=32, fill=0)
        if self.gvar != 0 and self.gv_offs != 0:
            var ncomp = 0
            while more and comp < len(self.d):
                ncomp += 1
                var fl = self.i16(comp)
                comp += 4
                comp += 4 if (fl & 1) != 0 else 2
                comp += 2 if (fl & 8) != 0 else (4 if (fl & 64) != 0 else (8 if (fl & 128) != 0 else 0))
                more = (fl & 32) != 0
            comp = g + 10
            more = True
            self._vary(gid, True, ncomp, 0, ofs_x, ofs_y, min(32, ncomp), out)
        var comp_idx = -1
        while more and comp < len(self.d):
            comp_idx += 1
            var flags = self.u16(comp)
            comp += 2
            var gidx = self.u16(comp)
            comp += 2
            var dx = 0
            var dy = 0
            var idx_base = 0
            var idx_comp = 0
            if flags & 2:
                if flags & 1:
                    dx = self.i16(comp)
                    dy = self.i16(comp + 2)
                    comp += 4
                else:
                    dx = _s8(self.u8(comp))
                    dy = _s8(self.u8(comp + 1))
                    comp += 2
            elif flags & 1:
                idx_base = self.u16(comp)
                idx_comp = self.u16(comp + 2)
                comp += 4
            else:
                idx_base = self.u8(comp)
                idx_comp = self.u8(comp + 1)
                comp += 2
            var m0 = Float32(1)
            var m1 = Float32(0)
            var m2 = Float32(0)
            var m3 = Float32(1)
            if flags & 8:
                m0 = Float32(self.i16(comp)) / 16384.0
                m3 = m0
                comp += 2
            elif flags & 64:
                m0 = Float32(self.i16(comp)) / 16384.0
                m3 = Float32(self.i16(comp + 2)) / 16384.0
                comp += 4
            elif flags & 128:
                m0 = Float32(self.i16(comp)) / 16384.0
                m1 = Float32(self.i16(comp + 2)) / 16384.0
                m2 = Float32(self.i16(comp + 4)) / 16384.0
                m3 = Float32(self.i16(comp + 6)) / 16384.0
                comp += 8
            var m = Float32(sqrt(Float64(m0 * m0 + m1 * m1)))
            var n = Float32(sqrt(Float64(m2 * m2 + m3 * m3)))
            if comp_idx < 32:
                dx += ofs_x[comp_idx]
                dy += ofs_y[comp_idx]
            var sub = self.glyph_shape(gidx)
            if len(sub.v) > 0:
                for k in range(len(sub.v)):
                    ref v = sub.v[k]
                    var x = Float32(v.x)
                    var y = Float32(v.y)
                    v.x = _i16(Int(m * (m0 * x + m2 * y + Float32(dx))))
                    v.y = _i16(Int(n * (m1 * x + m3 * y + Float32(dy))))
                    x = Float32(v.cx)
                    y = Float32(v.cy)
                    v.cx = _i16(Int(m * (m0 * x + m2 * y + Float32(dx))))
                    v.cy = _i16(Int(n * (m1 * x + m3 * y + Float32(dy))))
                if not (flags & 2):
                    var ddx = out.v[idx_base].x - sub.v[idx_comp].x
                    var ddy = out.v[idx_base].y - sub.v[idx_comp].y
                    for k in range(len(sub.v)):
                        ref v = sub.v[k]
                        v.x = _i16(v.x + ddx)
                        v.y = _i16(v.y + ddy)
                        v.cx = _i16(v.cx + ddx)
                        v.cy = _i16(v.cy + ddy)
                for k in range(len(sub.v)):
                    out.v.append(sub.v[k].copy())
            more = (flags & 32) != 0

    # ---- variable fonts: filled in by the gvar stage ----
    def _read_fvar(mut self, fvar: Int) raises:
        pass

    def _read_gvar(mut self) raises:
        pass

    def set_instance(mut self, tag: Int, value: Int):
        """stbtt_SetInstance for one axis (tag -1 = reset every axis to its default); `value` is 16.16."""
        pass

    def _vary(self, gid: Int, composite: Bool, nc: Int, end_pts: Int, mut xs: List[Int], mut ys: List[Int], out_count: Int, mut box: Shape):
        pass


def _s8(v: Int) -> Int:
    return v - 256 if v >= 128 else v


def _close_shape(mut v: List[Vertex], was_off: Bool, start_off: Bool, sx: Int, sy: Int, scx: Int, scy: Int, cx: Int, cy: Int):
    if start_off:
        if was_off:
            v.append(Vertex(VCURVE, _i16((cx + scx) >> 1), _i16((cy + scy) >> 1), _i16(cx), _i16(cy)))
        v.append(Vertex(VCURVE, _i16(sx), _i16(sy), _i16(scx), _i16(scy)))
    elif was_off:
        v.append(Vertex(VCURVE, _i16(sx), _i16(sy), _i16(cx), _i16(cy)))
    else:
        v.append(Vertex(VLINE, _i16(sx), _i16(sy), 0, 0))


def _find_table(d: List[UInt8], tag: String) -> Int:
    var n = (Int(d[4]) << 8) | Int(d[5])
    var t = tag.as_bytes()
    for i in range(n):
        var rec = 12 + 16 * i
        if d[rec] == t[0] and d[rec + 1] == t[1] and d[rec + 2] == t[2] and d[rec + 3] == t[3]:
            return (Int(d[rec + 8]) << 24) | (Int(d[rec + 9]) << 16) | (Int(d[rec + 10]) << 8) | Int(d[rec + 11])
    return 0
