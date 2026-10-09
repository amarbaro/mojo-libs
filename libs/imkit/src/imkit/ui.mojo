"""Immediate-mode UI drawn by the GPU (docs/RENDERER.md, GUI). Every frame the host calls widgets with this frame's Input;
each widget returns its interaction (clicked, toggled, dragged) and appends draw commands to one flat list. The list is
binned into 16 x 16 tiles on the host; `compose` gives every UI pixel one thread that walks only its tile's commands in
order: anti-aliased rounded rects and soft shadows by SDF, glyphs from font.mojo's atlas, capsule lines, triangles,
alpha "over". The result is a UW x UH straight-alpha RGBA layer that window.mojo blends over the scene.

Command: CW uint32 = kind, x0, y0, x1, y1, r, rgba, aux (floats stored as bits). rect: r = corner radius, aux = blur
(soft shadow); glyph: aux = atlas x | atlas y << 16; line: (x0, y0)-(x1, y1), r = half width; tri: (x0, y0), (x1, y1),
(r, aux) as the third corner.
"""
from std.math import sqrt
from std.memory import bitcast
from std.sys import get_defined_int
from max.gpu import block_dim, block_idx, thread_idx
from layout import TileTensor, row_major
from font import AW, Font
from window import Input

comptime UW = get_defined_int["UI_W", 1280]()
comptime UH = get_defined_int["UI_H", 720]()
comptime TILE = 16
comptime TX = UW // TILE
comptime TY = UH // TILE
comptime TCAP = 64  # commands per tile (more are dropped and counted)
comptime NCMD = 4096
comptime CW = 8
comptime AH = 256  # atlas rows on the card (font.mojo packs ~120 for three sizes)
comptime RECT = 0
comptime GLYPH = 1
comptime LINE = 2
comptime TRI = 3

comptime TUI = TileTensor[DType.uint32, type_of(row_major[UW * UH]()), MutAnyOrigin]
comptime TCMD = TileTensor[DType.uint32, type_of(row_major[NCMD * CW]()), MutAnyOrigin]
comptime TBIN = TileTensor[DType.uint16, type_of(row_major[TX * TY * TCAP]()), MutAnyOrigin]
comptime TCNT = TileTensor[DType.uint32, type_of(row_major[TX * TY]()), MutAnyOrigin]
comptime TATL = TileTensor[DType.uint8, type_of(row_major[AW * AH]()), MutAnyOrigin]

# theme: dark glass panels, one indigo accent (rgba packed r | g << 8 | b << 16 | a << 24)
comptime PANEL = rgba(17, 19, 26, 214)
comptime SURFACE = rgba(36, 40, 52, 255)
comptime HOVER = rgba(52, 57, 74, 255)
comptime ACCENT = rgba(99, 102, 241, 255)
comptime GOOD = rgba(52, 211, 153, 255)
comptime WARN = rgba(251, 191, 36, 255)
comptime BAD = rgba(248, 113, 113, 255)
comptime TEXT = rgba(229, 231, 235, 255)
comptime MUTED = rgba(148, 155, 172, 255)
comptime SHADOW = rgba(0, 0, 0, 120)


def rgba(r: Int, g: Int, b: Int, a: Int) -> UInt32:
    return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24


@always_inline
def bits(x: Float32) -> UInt32:
    return bitcast[DType.uint32](x)


@always_inline
def flt(u: UInt32) -> Float32:
    return bitcast[DType.float32](u)


def compose(img: TUI, cmd: TCMD, bin: TBIN, cnt: TCNT, atlas: TATL):
    var i = Int(block_idx.x * block_dim.x + thread_idx.x)
    if i >= UW * UH:
        return
    var px = Float32(i % UW) + 0.5
    var py = Float32(i // UW) + 0.5
    var t = (i // UW // TILE) * TX + (i % UW) // TILE
    var r = Float32(0)
    var g = Float32(0)
    var b = Float32(0)
    var a = Float32(0)  # premultiplied accumulation
    for k in range(Int(min(cnt[t], UInt32(TCAP)))):
        var o = Int(bin[t * TCAP + k]) * CW
        var kind = Int(cmd[o])
        var x0 = flt(cmd[o + 1])
        var y0 = flt(cmd[o + 2])
        var x1 = flt(cmd[o + 3])
        var y1 = flt(cmd[o + 4])
        var rr = flt(cmd[o + 5])
        var c = cmd[o + 6]
        var cov = Float32(0)
        if kind == RECT:
            var soft = flt(cmd[o + 7])
            var qx = abs(px - (x0 + x1) * 0.5) - (x1 - x0) * 0.5 + rr
            var qy = abs(py - (y0 + y1) * 0.5) - (y1 - y0) * 0.5 + rr
            var d = sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - rr
            cov = min(max(0.5 - d / (1 + soft), Float32(0)), Float32(1))
        elif kind == GLYPH:
            if px >= x0 and px < x1 and py >= y0 and py < y1:
                var ax = Int(cmd[o + 7] & 0xFFFF) + Int(px - x0)
                var ay = Int(cmd[o + 7] >> 16) + Int(py - y0)
                cov = Float32(atlas[ay * AW + ax]) / 255
        elif kind == LINE:
            var bx = x1 - x0
            var by = y1 - y0
            var h = min(max(((px - x0) * bx + (py - y0) * by) / max(bx * bx + by * by, 1e-6), Float32(0)), Float32(1))
            var dx = px - x0 - bx * h
            var dy = py - y0 - by * h
            cov = min(max(0.5 - (sqrt(dx * dx + dy * dy) - rr), Float32(0)), Float32(1))
        else:  # TRI: largest signed edge distance (corners counter-clockwise on screen)
            var x2 = rr
            var y2 = flt(cmd[o + 7])
            var d = Float32(-1e9)
            for e in range(3):
                var ax = x0 if e == 0 else (x1 if e == 1 else x2)
                var ay = y0 if e == 0 else (y1 if e == 1 else y2)
                var cx = x1 if e == 0 else (x2 if e == 1 else x0)
                var cy = y1 if e == 0 else (y2 if e == 1 else y0)
                var ex = cx - ax
                var ey = cy - ay
                d = max(d, ((px - ax) * ey - (py - ay) * ex) / max(sqrt(ex * ex + ey * ey), 1e-6))
            cov = min(max(0.5 - d, Float32(0)), Float32(1))
        var sa = cov * Float32(c >> 24) / 255
        r = Float32(c & 255) / 255 * sa + r * (1 - sa)
        g = Float32((c >> 8) & 255) / 255 * sa + g * (1 - sa)
        b = Float32((c >> 16) & 255) / 255 * sa + b * (1 - sa)
        a = sa + a * (1 - sa)
    var inv = 1 / max(a, Float32(1e-6))  # straight alpha out (SDL blends straight alpha)
    img[i] = UInt32(min(r * inv, 1) * 255) | UInt32(min(g * inv, 1) * 255) << 8 | UInt32(min(b * inv, 1) * 255) << 16 | UInt32(a * 255) << 24


struct Ui(Movable):
    var font: Font
    var cmd: List[UInt32]
    var n: Int
    var bins: List[UInt16]
    var cnt: List[UInt32]
    var dropped: Int
    var inp: Input
    var active: Int  # widget held by the mouse (0: none)
    var over: Bool  # the mouse is over UI this frame: the scene does not take it
    var x: Float32  # layout cursor
    var y: Float32

    def __init__(out self, var font: Font):
        self.font = font^
        self.cmd = List[UInt32](length=NCMD * CW, fill=0)
        self.bins = List[UInt16](length=TX * TY * TCAP, fill=0)
        self.cnt = List[UInt32](length=TX * TY, fill=0)
        self.n, self.dropped, self.active, self.over, self.x, self.y = 0, 0, 0, False, 0, 0
        self.inp = Input(0, 0, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)

    def begin(mut self, inp: Input):
        self.inp = inp.copy()
        self.n = 0
        self.over = False

    def push(mut self, kind: Int, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, c: UInt32, aux: UInt32 = 0):
        if self.n == NCMD:
            self.dropped += 1
            return
        var o = self.n * CW
        self.cmd[o], self.cmd[o + 1], self.cmd[o + 2], self.cmd[o + 3] = UInt32(kind), bits(x0), bits(y0), bits(x1)
        self.cmd[o + 4], self.cmd[o + 5], self.cmd[o + 6], self.cmd[o + 7] = bits(y1), bits(r), c, aux
        self.n += 1

    def rect(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, c: UInt32, blur: Float32 = 0):
        self.push(RECT, x0, y0, x1, y1, r, c, bits(blur))

    def line(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, w: Float32, c: UInt32):
        self.push(LINE, x0, y0, x1, y1, w * 0.5, c)

    def tri(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, x2: Float32, y2: Float32, c: UInt32):
        self.push(TRI, x0, y0, x1, y1, x2, c, bits(y2))

    def text(mut self, x: Float32, y: Float32, s: StringSlice, size: Int, c: UInt32) -> Float32:
        """Draw s with its top at y; returns the x after it."""
        var pen = x
        var base = y + Float32(self.font.ascent[size])
        for ch in s.as_bytes():
            var g = self.font.glyph(size, Int(ch))
            var w = Float32(self.font.g[g + 2])
            if w > 0:
                var gx = pen + Float32(self.font.g[g + 4])
                var gy = base - Float32(self.font.g[g + 5])
                self.push(GLYPH, gx, gy, gx + w, gy + Float32(self.font.g[g + 3]), 0, c,
                          UInt32(self.font.g[g]) | UInt32(self.font.g[g + 1]) << 16)
            pen += Float32(self.font.g[g + 6])
        return pen

    def hovered(self, x0: Float32, y0: Float32, x1: Float32, y1: Float32) -> Bool:
        return x0 <= self.inp.x < x1 and y0 <= self.inp.y < y1

    def clickable(mut self, id: Int, x0: Float32, y0: Float32, x1: Float32, y1: Float32) -> Tuple[Bool, Bool]:
        """(hovered, clicked): a press inside makes id active, a release inside while active is the click."""
        var h = self.hovered(x0, y0, x1, y1)
        if h and self.inp.pressed & 1:
            self.active = id
        return (h, h and self.active == id and self.inp.released & 1 != 0)

    def panel(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, title: StringSlice):
        """Glass panel with a soft shadow and a title; the layout cursor starts under the title."""
        self.rect(x0 + 2, y0 + 6, x1 + 2, y1 + 10, 14, SHADOW, 14)
        self.rect(x0, y0, x1, y1, 12, PANEL)
        _ = self.text(x0 + 16, y0 + 12, title, 1, TEXT)
        if self.hovered(x0, y0, x1, y1):
            self.over = True
        self.x, self.y = x0 + 16, y0 + 40

    def button(mut self, id: Int, label: StringSlice, w: Float32, h: Float32 = 30, on: Bool = False) -> Bool:
        """Pill button at the cursor (also a toggle: on = filled with the accent); returns clicked."""
        var x0, y0 = self.x, self.y
        var hc = self.clickable(id, x0, y0, x0 + w, y0 + h)
        self.rect(x0, y0, x0 + w, y0 + h, h * 0.5, ACCENT if on else (HOVER if hc[0] else SURFACE))
        var tw = Float32(self.font.width(label, 0))
        _ = self.text(x0 + (w - tw) * 0.5, y0 + (h - Float32(self.font.ascent[0])) * 0.5 - 1, label, 0, TEXT)
        self.x += w + 8
        return hc[1]

    def icon(mut self, id: Int, kind: Int, on: Bool = False) -> Bool:
        """Round icon button at the cursor: 0 play, 1 pause, 2 step, 3 stop; returns clicked."""
        var x0, y0 = self.x, self.y
        var hc = self.clickable(id, x0, y0, x0 + 36, y0 + 36)
        self.rect(x0, y0, x0 + 36, y0 + 36, 18, ACCENT if on else (HOVER if hc[0] else SURFACE))
        var cx, cy = x0 + 18, y0 + 18
        if kind == 0 or kind == 2:
            self.tri(cx - 5, cy - 7, cx - 5, cy + 7, cx + 7, cy, TEXT)
        if kind == 1:
            self.rect(cx - 6, cy - 7, cx - 2, cy + 7, 1.5, TEXT)
            self.rect(cx + 2, cy - 7, cx + 6, cy + 7, 1.5, TEXT)
        if kind == 2:
            self.rect(cx + 7, cy - 7, cx + 10, cy + 7, 1, TEXT)
        if kind == 3:
            self.rect(cx - 6, cy - 6, cx + 6, cy + 6, 2, TEXT)
        self.x += 44
        return hc[1]

    def bar(mut self, label: StringSlice, v: Float32, c: UInt32, w: Float32):
        """Label and a rounded progress bar of v in 0..1 at the cursor; next row."""
        _ = self.text(self.x, self.y, label, 0, MUTED)
        var x0 = self.x + 64
        self.rect(x0, self.y + 4, x0 + w - 64, self.y + 12, 4, SURFACE)
        self.rect(x0, self.y + 4, x0 + (w - 64) * min(max(v, 0), 1), self.y + 12, 4, c)
        self.y += 20

    def spark(mut self, vals: List[Float32], lo: Float32, hi: Float32, w: Float32, h: Float32, c: UInt32):
        """Line chart of vals (oldest first) in a w x h box at the cursor, with the last point marked; next row."""
        var x0, y0 = self.x, self.y
        self.rect(x0, y0, x0 + w, y0 + h, 6, SURFACE)
        var n = len(vals)
        for k in range(1, n):
            var ya = y0 + h - 3 - (h - 6) * (vals[k - 1] - lo) / max(hi - lo, 1e-6)
            var yb = y0 + h - 3 - (h - 6) * (vals[k] - lo) / max(hi - lo, 1e-6)
            self.line(x0 + w * Float32(k - 1) / Float32(max(n - 1, 1)), ya, x0 + w * Float32(k) / Float32(max(n - 1, 1)), yb, 1.6, c)
        self.y += h + 8

    def finish(mut self):
        """End the frame: a release ends the active widget (after every widget saw it); bin the commands into tiles."""
        if self.inp.released & 1:
            self.active = 0
        for k in range(TX * TY):
            self.cnt[k] = 0
        for k in range(self.n):
            var o = k * CW
            var x0 = flt(self.cmd[o + 1])
            var y0 = flt(self.cmd[o + 2])
            var x1 = flt(self.cmd[o + 3])
            var y1 = flt(self.cmd[o + 4])
            var pad = Float32(2)
            if Int(self.cmd[o]) == RECT:
                pad += 2 * flt(self.cmd[o + 7])
            if Int(self.cmd[o]) == LINE:
                pad += flt(self.cmd[o + 5])
            var lx = min(x0, x1)
            var hx = max(x0, x1)
            var ly = min(y0, y1)
            var hy = max(y0, y1)
            if Int(self.cmd[o]) == TRI:
                lx = min(lx, flt(self.cmd[o + 5]))
                hx = max(hx, flt(self.cmd[o + 5]))
                ly = min(ly, flt(self.cmd[o + 7]))
                hy = max(hy, flt(self.cmd[o + 7]))
            for ty in range(max(Int(ly - pad) // TILE, 0), min(Int(hy + pad) // TILE + 1, TY)):
                for tx in range(max(Int(lx - pad) // TILE, 0), min(Int(hx + pad) // TILE + 1, TX)):
                    var t = ty * TX + tx
                    if self.cnt[t] < TCAP:
                        self.bins[t * TCAP + Int(self.cnt[t])] = UInt16(k)
                    else:
                        self.dropped += 1
                    self.cnt[t] += 1
