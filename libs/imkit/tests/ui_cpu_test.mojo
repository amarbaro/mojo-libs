"""Ui check without a GPU or a window: scripted input through widgets, the draw list and its tile bins.
Gates: a click is press then release on the same widget (not a press alone, not a second release); a press elsewhere
makes no click; the panel's command sits in the bin of a tile it covers and not in a far tile; bins hold exactly the
entries the spans predict; a frame past NBIN tile entries drops whole commands, counted, and keeps off[last] <= NBIN;
a list past NCMD commands drops, counted; text fields: typing keeps ASCII 32-126, Backspace, a maximum length, focus by click and
the focused flag; image_fits (set_image's check) and an image rect larger than the layer clipped to its tiles. PASS / FAIL, exit 1 on any FAIL.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/ui_cpu_test.mojo  (default font: Roboto Medium)
"""
from std.os import getenv
from imkit.draw import flt
from imkit.font import Font
from imkit.layer import image_fits
from imkit.draw import ISRC, NBIN, NCMD, NSTY, TX, TY, UH, UW, FULL, bits, clipped, rgba, rrect, srect
from imkit.theme import ACCENT
from imkit.ui import SC_BACKSPACE, Ui
from imkit.window import Input


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def in_bin(ui: Ui, tile: Int, k: Int) -> Bool:
    for j in range(Int(ui.d.off[tile]), Int(ui.d.off[tile + 1])):
        if Int(ui.d.bins[j]) == k:
            return True
    return False


def frame(mut ui: Ui, inp: Input) -> Bool:
    ui.begin(inp)
    ui.panel(24, 20, 520, 96, "Run")
    _ = ui.icon(1, 0)
    var paused = ui.icon(2, 1, True)  # the second icon: x 84 to 120, y 60 to 96
    _ = ui.icon(3, 2)
    ui.finish()
    return paused


def typed(mut ui: Ui, mut a: String, mut b: String, inp: Input) -> Bool:
    """One frame with two fields (ids 1 and 2, max 8 and 4); True if the first changed."""
    ui.begin(inp)
    ui.x, ui.y = 10, 10  # field 1: y 10 to 40, field 2: y 48 to 78
    var c = ui.field(1, a, 8)
    _ = ui.field(2, b, 4)
    ui.finish()
    return c


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var fails = 0
    var keys = SIMD[DType.uint64, 2](0)
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False)
    var press = Input(102, 78, 0, 0, 0, 1, 1, 0, keys, False)
    var release = Input(102, 78, 0, 0, 0, 0, 0, 1, keys, False)
    var elsewhere = Input(400, 300, 0, 0, 0, 1, 1, 0, keys, False)
    var elsewhere_up = Input(400, 300, 0, 0, 0, 0, 0, 1, keys, False)
    var c0 = frame(ui, idle)
    var c1 = frame(ui, press)
    var c2 = frame(ui, release)
    var c3 = frame(ui, release)
    check(not c0 and not c1 and c2 and not c3, "click is press then release on the icon, once", fails)
    var e1 = frame(ui, elsewhere)
    var e2 = frame(ui, elsewhere_up)
    check(not e1 and not e2, "press and release elsewhere is no click", fails)
    check(ui.d.dropped == 0 and ui.d.n > 10, "demo frame: commands kept, none dropped", fails)
    # the panel background is the second command (shadow first); it covers tile (60 / 16, 400 / 16) and not the far corner
    var near = (60 // 16) * TX + 400 // 16
    var far = (TY - 1) * TX + (TX - 1)
    check(in_bin(ui, near, 1) and not in_bin(ui, far, 1), "panel command is in a covered tile's bin and not in a far one", fails)
    var total = 0
    for k in range(ui.d.n):
        var s = ui.d.span(k)
        total += Int(s[1] - s[0]) * Int(s[3] - s[2])
    check(Int(ui.d.off[TX * TY]) == total and total <= NBIN, "bin entries equal the sum of the spans", fails)
    # tile entry overflow: full-screen rects touch every tile; past NBIN whole commands drop
    ui.d.dropped = 0
    ui.begin(idle)
    var want = NBIN // (TX * TY) + 5
    for _ in range(want):
        ui.rect(0, 0, Float32(TX * 16), Float32(TY * 16), 0, ACCENT)
    ui.finish()
    check(ui.d.n == NBIN // (TX * TY) and ui.d.dropped == want - NBIN // (TX * TY) and Int(ui.d.off[TX * TY]) <= NBIN, "past NBIN whole commands drop, counted", fails)
    # command list overflow
    ui.d.dropped = 0
    ui.begin(idle)
    for _ in range(NCMD + 10):
        ui.rect(0, 0, 4, 4, 0, ACCENT)
    check(ui.d.n == NCMD and ui.d.dropped == 10, "past NCMD commands drop, counted", fails)
    # text fields
    var back = SIMD[DType.uint64, 2](0)
    back[SC_BACKSPACE >> 6] = UInt64(1) << UInt64(SC_BACKSPACE & 63)
    var a = String()
    var b = String()
    var fui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var t0 = typed(fui, a, b, idle)
    check(not t0 and fui.field_focused and fui.focus == 1, "first field drawn takes focus, flag set, nothing typed", fails)
    var t1 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "Ab 1" + chr(7) + chr(233) + "~"))
    check(t1 and a == "Ab 1~" and b == "", "typing keeps ASCII 32-126 only, goes to the focused field", fails)
    var t2 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, back, False))
    check(t2 and a == "Ab 1", "Backspace removes the last byte", fails)
    var t3 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "xyz12345"))
    check(t3 and a == "Ab 1xyz1" and a.byte_length() == 8, "typing stops at max", fails)
    var t4 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "q"))
    check(not t4 and a == "Ab 1xyz1", "a full field reports no change", fails)
    var e = String()
    _ = typed(fui, e, b, Input(300, 300, 0, 0, 0, 0, 0, 0, back, False))
    check(e == "", "Backspace on an empty field does nothing", fails)
    _ = typed(fui, a, b, Input(50, 60, 0, 0, 0, 1, 1, 0, keys, False))  # press on field 2
    _ = typed(fui, a, b, Input(50, 60, 0, 0, 0, 0, 0, 1, keys, False))  # release: click
    check(fui.focus == 2, "a click gives the field focus", fails)
    _ = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "hello"))
    check(a == "Ab 1xyz1" and b == "hell", "the second field takes the typing, max 4", fails)
    fui.begin(idle)
    fui.finish()
    check(not fui.field_focused, "no field drawn: flag clear", fails)
    # set_image's fit rule: ISRC pixels at most, sides up to 0xFFFF, the slice must hold w * h
    check(image_fits(16, 4, 4) and image_fits(ISRC, 256, ISRC // 256) and not image_fits(ISRC + 256, 256, ISRC // 256 + 1) and not image_fits(15, 4, 4)
          and not image_fits(16, 0, 4) and not image_fits(16, 4, -4) and not image_fits(16, 0x10000, 1), "image_fits: fits, raises on over ISRC, short slice, bad sides", fails)
    # a 4 x 4 image on a rect much larger than the layer (and one starting off-screen) is clipped to the tiles, not dropped
    fui.d.dropped = 0
    fui.begin(idle)
    fui.image(-300, -200, Float32(UW + 300), Float32(UH + 200), 0, 4, 4)
    fui.finish()
    check(fui.d.dropped == 0 and fui.d.n == 1 and Int(fui.d.off[TX * TY]) == TX * TY, "oversize image rect clipped to the layer's tiles", fails)
    # RRECT (100, 100)-(200, 160), r 10, fill (200, 100, 50), border 4 px green, glow 8 px: closed-form pixels of the shader
    var z = SIMD[DType.float32, 4](0)
    var fc, bcn = rgba(200, 100, 50, 255), rgba(0, 255, 0, 255)
    var k = UInt32(5) | UInt32(16) << 8 | UInt32(8) << 16
    var near4 = lambda (v: SIMD[DType.float32, 4], r: Float32, g: Float32, b: Float32, a: Float32) -> Bool: abs(v[0] - r) < 0.01 and abs(v[1] - g) < 0.01 and abs(v[2] - b) < 0.01 and abs(v[3] - a) < 0.01
    check(near4(rrect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 200 / 255, 100 / 255, 50 / 255, 1), "rrect: fill inside", fails)
    check(near4(rrect(z, 102.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 1, 0, 1), "rrect: border ring in bcol", fails)
    check(near4(rrect(z, 96.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 0.31640625, 0, 0.31640625), "rrect: glow 3.5 px out of 8 is (1 - 3.5 / 8) squared", fails)
    check(near4(rrect(z, 50.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 0, 0, 0), "rrect: nothing past the glow", fails)
    var gtop = rrect(z, 150.5, 100.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(127) << 24, 0)
    var gbot = rrect(z, 150.5, 159.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(127) << 24, 0)
    check(abs(gtop[0] * 255 - 254.08) < 0.1 and abs(gbot[0] * 255 - 3.3) < 0.1, "rrect: gradient + lightens the top and darkens the bottom", fails)
    var gneg = rrect(z, 150.5, 100.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(129) << 24, 0)
    check(gneg[0] * 255 < 4, "rrect: gradient byte 129 is -127 (top darker)", fails)
    var rui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    rui.begin(idle)
    rui.rrect(100, 100, 116, 116, 0, fc, 4, bcn, 40, -127)
    rui.rrect(100, 100, 116, 116, 0, fc)
    rui.finish()
    check(rui.d.cmd[0] == (UInt32(5) | UInt32(16) << 8 | UInt32(40) << 16 | UInt32(129) << 24) and rui.d.cmd[8] == 5 and rui.d.cmd[7] == bcn, "rrect: kind word packs border px * 4, glow px, gradient i8; aux is bcol", fails)
    check(rui.d.span(0)[0] == 3 and rui.d.span(1)[0] == 6, "rrect: span grows by the glow radius", fails)
    # SRECT, same rect, fill (200, 100, 50) to (0, 100, 250): linear down the rect, radial from its centre, a shadow moved 10 px down
    var lin = SIMD[DType.uint32, 8](1, rgba(0, 100, 250, 255), bits(0), bits(1), 0, 0, 0, 0)
    var rad = SIMD[DType.uint32, 8](2, rgba(0, 100, 250, 255), 0, 0, 0, 0, 0, 0)
    var shd = SIMD[DType.uint32, 8](0, 0, 0, 0, bits(0), bits(10), bits(4), rgba(0, 0, 0, 255))
    var sk = UInt32(6)
    check(abs(srect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, lin)[0] * 255 - 98.3) < 0.2, "srect: linear gradient is the mix at v = 0.508", fails)
    check(abs(srect(z, 180.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, rad)[0] * 255 - 77.96) < 0.2, "srect: radial gradient is the mix at 2 * distance from the centre", fails)
    check(near4(srect(z, 150.5, 163.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 0, 0, 0, 1), "srect: shadow moved 10 px down covers 3.5 px under the rect", fails)
    check(near4(srect(z, 150.5, 171.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 0, 0, 0, 0.2), "srect: shadow edge 1.5 px past its box is 0.2", fails)
    check(near4(srect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 200 / 255, 100 / 255, 50 / 255, 1), "srect: fill covers its shadow", fails)
    rui.begin(idle)
    var sid = rui.style(0, 0, 0, 1, 0, 30, 20, rgba(0, 0, 0, 200))
    var nid = rui.style(rgba(1, 2, 3, 255), 1)
    rui.srect(100, 100, 116, 116, 0, fc, sid)
    rui.srect(100, 100, 116, 116, 0, fc, nid)
    rui.finish()
    check(sid == 1 and nid == 2 and rui.d.cmd[0] == (UInt32(6) | UInt32(1) << 16) and rui.d.cmd[8] == (UInt32(6) | UInt32(2) << 16), "srect: style ids count from 1 and sit in the kind word's high 16 bits", fails)
    check(rui.d.span(0)[2] == 1 and rui.d.span(1)[2] == 6 and rui.d.span(0)[3] == 12, "srect: span grows by the larger shadow offset plus twice its radius (72 px here), not for a style without one", fails)
    rui.begin(idle)
    for _ in range(NSTY + 4):
        _ = rui.style()
    check(rui.d.ns == NSTY and rui.d.dropped >= 5, "style table full: counted, id 0", fails)
    # CLIP: pixels at the edge, and the bins: a clipped command is only in the clip's tiles, an unclipped one in all it covers
    var cr = SIMD[DType.float32, 4](10, 10, 20, 20)
    check(not clipped(10, 10, cr) and not clipped(19.5, 19.5, cr) and clipped(20, 15, cr) and clipped(15, 20, cr) and clipped(9.9, 15, cr) and clipped(15, 9.9, cr) and not clipped(-5, 1e6, FULL), "clip: half-open rect, FULL clips nothing", fails)
    rui.begin(idle)
    rui.clip(32, 32, 64, 64)
    rui.rect(0, 0, 1000, 700, 0, fc)
    rui.unclip()
    rui.rect(0, 0, 1000, 700, 0, fc)
    rui.unclip()  # none in force: no command
    rui.finish()
    check(rui.d.n == 4 and in_bin(rui, 2 * TX + 2, 1) and in_bin(rui, 4 * TX + 4, 1) and not in_bin(rui, 0, 1) and not in_bin(rui, 5 * TX + 5, 1) and not in_bin(rui, 2 * TX + 5, 1), "clip: a clipped command is binned only into the clip's tiles", fails)
    check(in_bin(rui, 0, 3) and in_bin(rui, 5 * TX + 5, 3) and in_bin(rui, 2 * TX + 2, 2) and in_bin(rui, 0, 0) == False, "clip: after unclip the next command covers all its tiles; the end marker sits in the clip's tiles", fails)
    # animation: begin(input, dt) steps the id's spring, an id no widget asked for last frame is evicted
    var aui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    aui.begin(idle, 0.02)
    var first = aui.animate(9, 0)
    aui.begin(idle, 0.02)
    var stepped = aui.animate(9, 1)
    aui.begin(idle, 0.02)  # id 9 was asked for last frame: kept; nobody asks now
    aui.begin(idle, 0.02)
    check(first == 0 and abs(stepped - 0.104) < 1e-5 and len(aui.anim.id) == 0, "Ui.begin(input, dt): spring steps by dt, an unasked id is evicted", fails)
    # DPI: logical coordinates. The icon at logical (10, 10)-(46, 46) draws at that times the scale, and a click needs the
    # mouse (layer pixels) inside it: its center clicks, 0.2 past the right edge and 0.2 before the left edge do not, 0.2 inside the left edge does.
    for sc in [Float32(1), Float32(1.5), Float32(2)]:
        var dui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
        dui.set_scale(sc)
        var hits = List[Bool]()
        for px in [Float32(28), Float32(46.2), Float32(9.8), Float32(10.2)]:  # logical x of the mouse; y is 28
            var mx = px * sc
            var ps = Input(mx, 28 * sc, 0, 0, 0, 1, 1, 0, keys, False)
            var rl = Input(mx, 28 * sc, 0, 0, 0, 0, 0, 1, keys, False)
            for inp in [ps.copy(), rl.copy()]:
                dui.begin(inp)
                dui.x, dui.y = 10, 10
                var clicked = dui.icon(1, 0)
                dui.finish()
                if inp.released & 1:
                    hits.append(clicked)
        var x0 = flt(dui.d.cmd[1])
        var x1 = flt(dui.d.cmd[3])
        check(hits[0] and not hits[1] and not hits[2] and hits[3] and abs(x0 - 10 * sc) < 1e-4 and abs(x1 - 46 * sc) < 1e-4
              and abs(dui.w() * sc - Float32(UW)) < 1e-3, "DPI " + String(sc) + ": hit test in logical units, rect drawn at logical x scale", fails)
    if fails:
        raise Error("FAIL " + String(fails) + " ui_cpu checks")
    print("PASS ui_cpu_test")
