"""Asset atlas check (CPU): png_decode against tools/png_fixture.py's raw bytes (hand-written PNGs with every row filter, RGB and
RGBA, and one from Pillow's encoder), the formats it refuses, pack -> Assets round trip, and Ui.icon_img's image command.
usage: mojo run -I src tests/assets_test.mojo  (fixtures: tests/fixtures, regenerate with python3 tools/png_fixture.py)"""
from std.os import getenv
from imkit.assets import Assets, pack, png_decode
from imkit.draw import flt
from imkit.font import Font
from imkit.ui import Ui
from imkit.window import Input


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def same(png: String, raw: String) raises -> Bool:
    var p: List[UInt8]
    var r: List[UInt8]
    with open("tests/fixtures/" + png, "r") as f:
        p = f.read_bytes()
    with open("tests/fixtures/" + raw, "r") as f:
        r = f.read_bytes()
    var d = png_decode(Span(p))
    if d[0] != 24 or d[1] != 20 or len(d[2]) * 4 != len(r):
        return False
    for i in range(len(d[2])):
        if d[2][i] != UInt32(r[4 * i]) | UInt32(r[4 * i + 1]) << 8 | UInt32(r[4 * i + 2]) << 16 | UInt32(r[4 * i + 3]) << 24:
            return False
    return True


def refuses(var bytes: List[UInt8], at: Int, v: UInt8) -> Bool:
    if at >= 0:
        bytes[at] = v
    else:
        var cut = List[UInt8](bytes[: len(bytes) + at])
        bytes = cut^
    try:
        _ = png_decode(Span(bytes))
    except:
        return True
    return False


def main() raises:
    var fails = 0
    check(same("rgba.png", "rgba.raw"), "RGBA, row filters 0 to 4 cycling", fails)
    check(same("rgb.png", "rgb.raw"), "RGB: alpha 255", fails)
    check(same("pil.png", "pil.raw"), "a PNG from Pillow's encoder", fails)
    var good: List[UInt8]
    with open("tests/fixtures/rgba.png", "r") as f:
        good = f.read_bytes()
    check(refuses(good.copy(), 0, 0x88) and refuses(good.copy(), 24, 16) and refuses(good.copy(), 25, 3) and refuses(good.copy(), 28, 1) and refuses(good.copy(), -40, 0),
          "refused: bad signature, 16-bit, palette, interlaced, truncated", fails)
    check(not refuses(good.copy(), 24, 8), "an untouched IHDR is accepted", fails)
    pack(["tests/fixtures/rgba.png", "tests/fixtures/rgb.png", "tests/fixtures/pil.png"], ".work/assets_test")
    var a = Assets(".work/assets_test")
    check(len(a.px) == 3 * 480 and a.find("rgb") == 1 and a.meta[3] == 480 and a.meta[4] == 24 and a.meta[5] == 20 and a.find("pil") == 2 and a.meta[6] == 960 and a.find("nope") == -1,
          "pack then load: three pictures, offsets 0 / 480 / 960, names by file stem", fails)
    var rgba_ok = True
    var raw: List[UInt8]
    with open("tests/fixtures/rgba.raw", "r") as f:
        raw = f.read_bytes()
    for i in range(480):
        if a.px[i] != UInt32(raw[4 * i]) | UInt32(raw[4 * i + 1]) << 8 | UInt32(raw[4 * i + 2]) << 16 | UInt32(raw[4 * i + 3]) << 24:
            rgba_ok = False
    check(rgba_ok, "pack then load: the first picture's pixels are the oracle's", fails)
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    ui.assets = a^
    ui.begin(Input(0, 0, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False))
    var ok1 = ui.icon_img("rgb", 100, 50)
    var ok2 = ui.icon_img("pil", 200, 50, 48, 40, 128)
    var ok3 = ui.icon_img("nope", 0, 0)
    ui.finish()
    check(ok1 and ok2 and not ok3 and ui.d.n == 2 and ui.d.dropped == 1 and ui.d.cmd[0] == 4 and flt(ui.d.cmd[5]) == 480 and flt(ui.d.cmd[3]) == 124 and flt(ui.d.cmd[4]) == 70 and ui.d.cmd[7] == (24 | 20 << 16)
          and flt(ui.d.cmd[8 + 3]) == 248 and flt(ui.d.cmd[8 + 5]) == 960 and ui.d.cmd[8 + 6] >> 24 == 128,
          "icon_img: natural size, scaled size with alpha, unknown name counted", fails)
    if fails:
        print("FAIL", fails, "assets checks")
        raise Error("FAIL " + String(fails) + " assets checks")
    print("PASS assets_test")
