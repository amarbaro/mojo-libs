"""ui.mojo check (GPU, under gpu-wait): a top bar and a fly card built from widgets with scripted input, composed on the
card. Gates: the pause icon reports a click after press + release on it (and not elsewhere), no command dropped, a panel
pixel has the panel's alpha, a pixel outside every panel is transparent; compose timed over 1000 launches. OUT (.ppm)
gets the layer blended over a test background for a look.

usage: mojo run -I kinestride kinestride/ui_test.mojo [OUT.ppm]
"""
from std.sys import argv
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext
from layout import TileTensor, row_major
from font import AW, Font
from ui import ACCENT, AH, BAD, CW, GOOD, NCMD, TCAP, TEXT, TX, TY, UH, UW, WARN, Ui, compose
from window import Input


def frame(mut ui: Ui, inp: Input) -> Bool:
    """The demo layout; returns whether the pause icon was clicked."""
    ui.begin(inp)
    ui.panel(24, 20, 520, 96, "Run")
    _ = ui.icon(1, 0)
    var paused = ui.icon(2, 1, True)
    _ = ui.icon(3, 2)
    _ = ui.icon(4, 3)
    _ = ui.text(ui.x + 8, 58, "t 12.40 s   0.31x   62 fps", 0, TEXT)
    ui.panel(Float32(UW - 340), 20, Float32(UW - 24), 330, "Fly 1  walk")
    var names: List[String] = ["W", "A", "D", "space", "threat"]
    for k in range(5):
        _ = ui.button(10 + k, names[k], Float32(44 if k < 3 else 60), 28, k == 0)
    ui.x, ui.y = Float32(UW - 324), Float32(112)
    ui.bar("energy", 0.82, GOOD, 280)
    ui.bar("health", 0.95, ACCENT, 280)
    ui.bar("stamina", 0.41, WARN, 280)
    var vals = List[Float32]()
    for k in range(64):
        vals.append(Float32(k % 17) / 17 + Float32(k) / 128)
    ui.spark(vals, 0, 1.5, 284, 60, BAD)
    ui.finish()
    return paused


def main() raises:
    var ui = Ui(Font("/usr/share/fonts/TTF/Roboto-Medium.ttf", [13, 16, 22]))
    var fails = 0
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)
    var press = Input(102, 78, 0, 0, 0, 1, 1, 0, SIMD[DType.uint64, 2](0), False)  # on the pause icon (2nd icon)
    var release = Input(102, 78, 0, 0, 0, 0, 0, 1, SIMD[DType.uint64, 2](0), False)
    var c0 = frame(ui, idle)
    var c1 = frame(ui, press)
    var c2 = frame(ui, release)
    var c3 = frame(ui, release)  # a release with nothing active is no click
    print("clicks idle/press/release/again:", c0, c1, c2, c3, "commands", ui.n, "dropped", ui.dropped)
    if c0 or c1 or not c2 or c3 or ui.dropped:
        fails += 1
    var ctx = DeviceContext()
    var img_b = ctx.enqueue_create_buffer[DType.uint32](UW * UH)
    var cmd_b = ctx.enqueue_create_buffer[DType.uint32](NCMD * CW)
    var bin_b = ctx.enqueue_create_buffer[DType.uint16](TX * TY * TCAP)
    var cnt_b = ctx.enqueue_create_buffer[DType.uint32](TX * TY)
    var atl_b = ctx.enqueue_create_buffer[DType.uint8](AW * AH)
    var host = ctx.enqueue_create_host_buffer[DType.uint32](UW * UH)
    ctx.enqueue_copy(atl_b.create_sub_buffer[DType.uint8](0, len(ui.font.atlas)), ui.font.atlas.unsafe_ptr())
    ctx.enqueue_copy(cmd_b, ui.cmd.unsafe_ptr())
    ctx.enqueue_copy(bin_b, ui.bins.unsafe_ptr())
    ctx.enqueue_copy(cnt_b, ui.cnt.unsafe_ptr())
    var k = ctx.compile_function[compose]()
    var ti = TileTensor(img_b, row_major[UW * UH]())
    var tc = TileTensor(cmd_b, row_major[NCMD * CW]())
    var tb = TileTensor(bin_b, row_major[TX * TY * TCAP]())
    var tn = TileTensor(cnt_b, row_major[TX * TY]())
    var ta = TileTensor(atl_b, row_major[AW * AH]())
    ctx.enqueue_function(k, ti, tc, tb, tn, ta, grid_dim=(UW * UH + 255) // 256, block_dim=256)
    ctx.synchronize()
    var t0 = perf_counter_ns()
    for _ in range(1000):
        ctx.enqueue_function(k, ti, tc, tb, tn, ta, grid_dim=(UW * UH + 255) // 256, block_dim=256)
    ctx.synchronize()
    var us = Float64(perf_counter_ns() - t0) / 1000 / 1000
    ctx.enqueue_copy(host, img_b)
    ctx.synchronize()
    var inside = host[60 * UW + 400] >> 24  # inside the Run panel, away from widgets
    var outside = host[600 * UW + 600] >> 24
    print("compose", us, "us per launch at", UW, "x", UH, "; panel alpha", inside, "outside alpha", outside)
    if inside < 225 or inside > 240 or outside != 0:  # the glass panel (alpha 214) over its own soft shadow
        fails += 1
    # icon shapes (Run panel cursor x 40, y 60; icons 36 wide, 44 apart; centre +18): play triangle, pause bars
    var lum = lambda (p: UInt32) -> Int: Int(p & 255) + Int((p >> 8) & 255) + Int((p >> 16) & 255)
    var play = lum(host[78 * UW + 57])
    var bar_l = lum(host[78 * UW + 98])
    var gap = lum(host[78 * UW + 102])
    var bar_r = lum(host[78 * UW + 106])
    print("icon luminance: play centre", play, "pause bars", bar_l, bar_r, "gap", gap)
    if play < 600 or bar_l < 600 or bar_r < 600 or gap > 500:  # text-white shapes (sum ~687) on the surface or accent (sum 442)
        fails += 1
    if len(argv()) > 1:  # the layer over a test background, as SDL blends it
        var ppm = List[UInt8](capacity=UW * UH * 3)
        for i in range(UW * UH):
            var p = host[i]
            var a = Float32(p >> 24) / 255
            var bg: List[Float32] = [Float32(60 + (i % UW) * 80 // UW), Float32(90 + (i // UW) * 60 // UH), 70]
            for ch in range(3):
                ppm.append(UInt8(Float32((p >> UInt32(8 * ch)) & 255) * a + bg[ch] * (1 - a)))
        with open(String(argv()[1]), "w") as o:
            o.write("P6\n" + String(UW) + " " + String(UH) + "\n255\n")
            o.write_bytes(Span(ppm))
    if fails:
        raise Error("FAIL " + String(fails) + " ui checks")
    print("PASS ui_test")
