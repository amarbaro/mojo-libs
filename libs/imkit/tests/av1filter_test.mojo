"""Hand-computed checks of the AV1 post filters (spec 7.14 to 7.17). Expected rows come from the spec formulas worked by hand
(see tools/av1_wide_oracle.py for the wide filter); no pixel oracle until lane A integrates. Prints PASS or FAIL lines."""
from imkit.av1frame import Frame
from imkit.av1lf import LfInput, loop_filter

def show(v: List[Int]) -> String:
    var s = String("")
    for x in v:
        s += String(x) + " "
    return s^


def check(name: String, got: List[Int], want: List[Int], mut failures: Int):
    if got != want:
        failures += 1
        print("FAIL", name, "got", show(got), "want", show(want))


def row_of(frame: Frame, plane: Int, y: Int, x0: Int, n: Int) -> List[Int]:
    var r = List[Int]()
    for x in range(x0, x0 + n):
        r.append(frame.planes[plane].get(x, y))
    return r^


def step_frame(w: Int, h: Int, bd: Int, planes: Int, a: Int, b: Int, at: Int) -> Frame:
    """4:2:0 frame whose every row is `a` left of luma x = at and `b` from there (chroma: at >> 1)."""
    var f = Frame(w, h, bd, 1, 1, planes)
    for p in range(planes):
        var edge = at if p == 0 else at >> 1
        for y in range(f.planes[p].h):
            for x in range(f.planes[p].w):
                f.planes[p].set(x, y, a if x < edge else b)
    return f^


def lf_for(w: Int, h: Int, planes: Int, mi_size: Int, tx: Int, lvl: Int) -> LfInput:
    var inp = LfInput(2 * ((h + 7) >> 3), 2 * ((w + 7) >> 3), w, h, planes)
    for i in range(len(inp.mi_sizes)):
        inp.mi_sizes[i] = UInt8(mi_size)
    for p in range(planes):
        for i in range(len(inp.lf_tx_sizes[p])):
            inp.lf_tx_sizes[p][i] = UInt8(tx)
    for i in range(4):
        inp.loop_filter_level[i] = lvl
    return inp^


def main() raises:
    var failures = 0
    # BLOCK_16X16 = 6; TX_4X4 = 0, TX_8X8 = 1, TX_16X16 = 2
    var flat = Frame(32, 16, 8, 1, 1, 3)
    for p in range(3):
        for i in range(len(flat.planes[p].px)):
            flat.planes[p].px[i] = 128
    var inp = lf_for(32, 16, 3, 6, 0, 30)
    loop_filter(flat, inp)
    for p in range(3):
        for i in range(len(flat.planes[p].px)):
            if flat.planes[p].px[i] != 128:
                failures += 1
                print("FAIL flat frame changed in plane", p)
                break

    # 4-tap (narrow): 100 | 110, lvl 10: ps0 -28, qs0 -18, f 30, f1 4, f2 4, outer f 2 -> 102 104 | 106 108
    var f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    var want: List[Int] = [100, 100, 100, 100, 100, 100, 102, 104, 106, 108, 110, 110, 110, 110, 110, 110]
    for y in [0, 7, 15]:
        check("narrow y=" + String(y), row_of(f, 0, y, 8, 16), want, failures)

    # 8-tap luma wide filter (log2 3, n 3): 101 103 104 | 106 108 109
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 1, 10))
    check("wide8", row_of(f, 0, 5, 8, 16), [100, 100, 100, 100, 100, 101, 103, 104, 106, 108, 109, 110, 110, 110, 110, 110], failures)

    # 14-tap luma wide filter (log2 4, n 6), 16 wide transforms
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 2, 10))
    check("wide16", row_of(f, 0, 5, 8, 16), [100, 100, 101, 101, 102, 103, 103, 104, 106, 107, 108, 108, 109, 109, 110, 110], failures)

    # 10-bit narrow: 400 | 440 (thresholds shift by 2): 408 415 | 425 432
    f = step_frame(32, 16, 10, 1, 400, 440, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    check("narrow10", row_of(f, 0, 3, 8, 16), [400, 400, 400, 400, 400, 400, 408, 415, 425, 432, 440, 440, 440, 440, 440, 440], failures)

    # chroma 6-tap (log2 3, plane > 0: n 2, n2 1) at chroma x 8; V has level 0 and stays a step; luma flat
    f = step_frame(32, 16, 8, 3, 100, 110, 16)
    for i in range(len(f.planes[0].px)):
        f.planes[0].px[i] = 128
    inp = lf_for(32, 16, 3, 6, 1, 10)
    inp.loop_filter_level[3] = 0
    loop_filter(f, inp)
    check("chroma6 U", row_of(f, 1, 2, 0, 16), [100, 100, 100, 100, 100, 100, 101, 104, 106, 109, 110, 110, 110, 110, 110, 110], failures)
    check("chroma6 V untouched", row_of(f, 2, 2, 0, 16), [100, 100, 100, 100, 100, 100, 100, 100, 110, 110, 110, 110, 110, 110, 110, 110], failures)

    # mask rejects a big step (2 * 40 + 20 > blimit 34): unchanged
    f = step_frame(32, 16, 8, 1, 100, 140, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    check("mask reject", row_of(f, 0, 0, 14, 4), [100, 100, 140, 140], failures)

    # level 0 everywhere: nothing runs
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 0))
    check("level 0", row_of(f, 0, 0, 14, 4), [100, 100, 110, 110], failures)

    # step 13: blimit(lvl 9) = 31 < 2*13 + 6 = 32 <= blimit(lvl 10) = 34, so lvl 9 does nothing and lvl 9 + ref delta 1 filters
    f = step_frame(32, 16, 8, 1, 100, 113, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 9))
    check("lvl9 plain", row_of(f, 0, 0, 14, 4), [100, 100, 113, 113], failures)
    f = step_frame(32, 16, 8, 1, 100, 113, 16)
    inp = lf_for(32, 16, 1, 6, 0, 9)
    inp.loop_filter_delta_enabled = True  # RefFrames = INTRA_FRAME: ref_deltas[0] = 1
    loop_filter(f, inp)
    check("lvl9 + delta", row_of(f, 0, 0, 14, 4), [103, 105, 108, 110], failures)

    # segment feature ALT_LF_Y_V (feature 1) of segment 0 lifts level 0 to 10: same result as the plain narrow case
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    inp = lf_for(32, 16, 1, 6, 0, 0)
    inp.seg_feature_enabled[1] = True
    inp.seg_feature_data[1] = 10
    loop_filter(f, inp)
    check("segment lvl", row_of(f, 0, 0, 14, 4), [102, 104, 106, 108], failures)

    # hev (thresh = lvl >> 4 = 1, |p1 - p0| = 2): only p0 / q0 change: 101 105 | 111 113
    f = step_frame(32, 16, 8, 1, 101, 113, 16)
    for y in range(16):
        f.planes[0].set(15, y, 103)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 16))
    check("hev", row_of(f, 0, 4, 14, 4), [101, 105, 111, 113], failures)

    # level 40 + ref delta 1 << (40 >> 5) = 42: blimit 130, so step 53 (132) is rejected and step 52 (130) is filtered
    f = step_frame(32, 16, 8, 1, 100, 153, 16)
    inp = lf_for(32, 16, 1, 6, 0, 40)
    inp.loop_filter_delta_enabled = True
    loop_filter(f, inp)
    check("nshift reject", row_of(f, 0, 0, 14, 4), [100, 100, 153, 153], failures)
    f = step_frame(32, 16, 8, 1, 100, 152, 16)
    loop_filter(f, inp)
    check("nshift accept", row_of(f, 0, 0, 14, 4), [108, 115, 137, 144], failures)

    # unit right of the edge has level 0, the unit left of it (col 3) has DeltaLF +10: the edge takes the previous unit's level
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    inp = lf_for(32, 16, 1, 6, 0, 0)
    for r in range(4):
        inp.delta_lfs[(r * 8 + 3) * 4] = 10
    loop_filter(f, inp)
    check("prev unit level", row_of(f, 0, 0, 14, 4), [102, 104, 106, 108], failures)

    if failures == 0:
        print("PASS av1filter")
    else:
        print("FAIL av1filter:", failures, "checks")
