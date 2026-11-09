"""Immediate-mode widgets (docs/design.md). Every frame the host calls widgets with this frame's Input; each widget
returns its interaction (clicked, toggled, dragged) and appends draw commands to a `Draw` (draw.mojo) that finish() bins
for the compose kernel. Colors come from theme.mojo.
"""
from .draw import Draw, TX, TY, NBIN, NCMD, CW, UW, UH, ISRC, AH, rgba
from .font import Font
from .theme import ACCENT, BAD, GOOD, HOVER, MUTED, PANEL, SHADOW, SURFACE, TEXT, WARN
from .window import Input

comptime SC_BACKSPACE = 42  # SDL scancode


struct Ui(Movable):
    var d: Draw
    var inp: Input
    var active: Int  # widget held by the mouse (0: none)
    var over: Bool  # the mouse is over UI this frame: the scene does not take it
    var x: Float32  # layout cursor
    var y: Float32
    var focus: Int  # id of the text field that takes typing (0: none yet; the first field drawn takes it)
    var field_focused: Bool  # a field drawn this frame has focus: the app sends keys to typing, not to shortcuts

    def __init__(out self, var font: Font):
        self.d = Draw(font^)
        self.active, self.over, self.x, self.y = 0, False, 0, 0
        self.focus, self.field_focused = 0, False
        self.inp = Input(0, 0, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)

    def begin(mut self, inp: Input):
        self.inp = inp.copy()
        self.d.begin()
        self.over = False
        self.field_focused = False

    def rect(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, c: UInt32, blur: Float32 = 0):
        self.d.rect(x0, y0, x1, y1, r, c, blur)

    def rrect(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, c: UInt32, border: Float32 = 0,
              bcol: UInt32 = 0, glow: Float32 = 0, grad: Int = 0):
        self.d.rrect(x0, y0, x1, y1, r, c, border, bcol, glow, grad)

    def style(mut self, c1: UInt32 = 0, mode: Int = 0, gx: Float32 = 0, gy: Float32 = 1, sx: Float32 = 0, sy: Float32 = 0,
              sr: Float32 = 0, sc: UInt32 = 0) -> Int:
        return self.d.style(c1, mode, gx, gy, sx, sy, sr, sc)

    def srect(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, c: UInt32, style: Int, border: Float32 = 0, bcol: UInt32 = 0):
        self.d.srect(x0, y0, x1, y1, r, c, style, border, bcol)

    def clip(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32):
        self.d.clip(x0, y0, x1, y1)

    def unclip(mut self):
        self.d.unclip()

    def glass(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, r: Float32, tint: UInt32):
        self.d.glass(x0, y0, x1, y1, r, tint)

    def line(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, w: Float32, c: UInt32):
        self.d.line(x0, y0, x1, y1, w, c)

    def tri(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, x2: Float32, y2: Float32, c: UInt32):
        self.d.tri(x0, y0, x1, y1, x2, y2, c)

    def image(mut self, x0: Float32, y0: Float32, x1: Float32, y1: Float32, off: Int, sw: Int, sh: Int, alpha: Int = 255):
        self.d.image(x0, y0, x1, y1, off, sw, sh, alpha)

    def text(mut self, x: Float32, y: Float32, s: StringSlice, size: Int, c: UInt32) -> Float32:
        return self.d.text(x, y, s, size, c)

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

    def button(mut self, id: Int, label: StringSlice, w: Float32, h: Float32 = 30, on: Bool = False, color: UInt32 = ACCENT) -> Bool:
        """Pill button at the cursor (also a toggle: on = filled with `color`, the accent by default); returns clicked."""
        var x0, y0 = self.x, self.y
        var hc = self.clickable(id, x0, y0, x0 + w, y0 + h)
        self.rect(x0, y0, x0 + w, y0 + h, h * 0.5, color if on else (HOVER if hc[0] else SURFACE))
        var tw = Float32(self.d.font.width(label, 0))
        _ = self.text(x0 + (w - tw) * 0.5, y0 + (h - Float32(self.d.font.ascent[0])) * 0.5 - 1, label, 0, TEXT)
        self.x += w + 8
        return hc[1]

    def field(mut self, id: Int, mut buf: String, max: Int) -> Bool:
        """Single-line text box (360 x 30) at the cursor; next row. A click gives it focus, and so does the first field drawn
        while none has it. The focused field appends the ASCII 32-126 of this frame's Input.text up to `max` bytes, then
        removes the last byte on Backspace; a long text shows its tail. Returns True if buf changed."""
        var x0, y0, w = self.x, self.y, Float32(360)
        var hc = self.clickable(id, x0, y0, x0 + w, y0 + 30)
        if hc[1] or self.focus == 0:
            self.focus = id
        var on = self.focus == id
        var changed = False
        if on:
            self.field_focused = True
            var add = List[UInt8]()  # collect, then one append: `buf += chr(b)` aborted with a 96 GiB request
            for b in self.inp.text.as_bytes():
                if 32 <= Int(b) <= 126 and buf.byte_length() + len(add) < max:
                    add.append(b)
            if len(add) > 0:
                buf = buf + String(unsafe_from_utf8=Span(add))
                changed = True
            if self.inp.key(SC_BACKSPACE) and buf.byte_length() > 0:
                var keep = buf.byte_length() - 1
                var cut = String(unsafe_from_utf8=buf.as_bytes()[:keep])
                buf = cut^
                changed = True
        self.rect(x0 - 1.5, y0 - 1.5, x0 + w + 1.5, y0 + 31.5, 8, ACCENT if on else SURFACE)
        self.rect(x0, y0, x0 + w, y0 + 30, 7, HOVER if hc[0] and not on else SURFACE)
        var s = 0
        while s < buf.byte_length() and self.d.font.width(StringSlice(unsafe_from_utf8=buf.as_bytes()[s:]), 0) > Int(w) - 24:
            s += 1
        var pen = self.text(x0 + 10, y0 + (30 - Float32(self.d.font.ascent[0])) * 0.5 - 1, StringSlice(unsafe_from_utf8=buf.as_bytes()[s:]), 0, TEXT)
        if on:
            self.rect(pen + 1, y0 + 7, pen + 2.5, y0 + 23, 0.5, TEXT)
        self.y += 38
        return changed

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
        """End the frame: a release ends the active widget (after every widget saw it); bin the draw list."""
        if self.inp.released & 1:
            self.active = 0
        self.d.finish()
