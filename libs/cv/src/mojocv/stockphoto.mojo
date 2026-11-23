# stockphoto: the per-photo numbers `scripts/mcv-stockgroup` needs, in one pass over the decoded picture: sharpness
# (Laplacian variance and Tenengrad at the stockcheck analysis scale), exposure clip shares, the main subject's box,
# and the 64-bit hashes. The box is a background-difference mask, not a detector: the stock photos are objects on a
# dark cloth with a yellow tape measure in frame, so the tape (yellow, saturated) is masked out first, the cloth's
# grey level is the median of what is left, and the subject is what departs from it by more than 4 robust sigma.
from std.math import exp
from mojocv.mat import Mat
from mojocv.core import Args, par_dyn
from mojocv.imgproc import cvt_color, gaussian_blur, morph, components
from mojocv.stockcheck import sharpness, clipping, hashes, box_down, scale_factor, _load_any, _esc, _hex, _jn

comptime U8 = DType.uint8


def _shrink3(src: Mat[U8], f: Int) -> Mat[U8]:
    """Integer area shrink of a BGR image: each output channel is the rounded mean of an f x f block."""
    var o = Mat[U8](src.rows // f, src.cols // f, 3, False)
    var p = src.ptr()
    var q = o.ptr()
    for y in range(o.rows):
        for x in range(o.cols):
            for k in range(3):
                var s = 0
                for dy in range(f):
                    for dx in range(f):
                        s += Int(p[((y * f + dy) * src.cols + x * f + dx) * 3 + k])
                q[(y * o.cols + x) * 3 + k] = UInt8((s + f * f // 2) // (f * f))
    return o^


def _yellow(b: Int, g: Int, r: Int) -> Bool:
    """OpenCV hue (0..179) in 20..36 with saturation >= 140 and value >= 130: the tape's yellow (gold straps are paler)."""
    var v = max(r, g, b)
    var d = v - min(r, g, b)
    if v < 130 or d == 0 or d * 255 < 140 * v:
        return False
    var h = 30.0 * Float64(g - b) / Float64(d) if v == r else (60.0 + 30.0 * Float64(b - r) / Float64(d) if v == g else 120.0 + 30.0 * Float64(r - g) / Float64(d))
    if h < 0.0:
        h += 180.0
    return h >= 20.0 and h <= 36.0


def _hist_pick(h: List[Int], n: Int) -> Int:
    """Smallest value whose cumulative count reaches half of n."""
    var acc = 0
    for v in range(len(h)):
        acc += h[v]
        if acc * 2 >= n:
            return v
    return len(h) - 1


def subject_box(src: Mat[U8], L: Int, tape: Int, kmad: Float64, tmin: Float64, minshare: Float64, keepfrac: Float64, skinshare: Float64) raises -> List[Float64]:
    """[found, x0, y0, x1, y1, fgshare, mad, handshare]: the box (px of `src`, x1 and y1 exclusive) around the foreground regions
    that are at least `keepfrac` of the largest one and `minshare` of the picture. found = 0 when nothing departs
    from the background (an empty cloth, a lens cap). Works on the picture shrunk to a long edge near L."""
    if src.ch != 3:
        raise Error("subjectBox needs a 3-channel BGR image, got " + String(src.ch) + " channels")
    var f = scale_factor(src.rows, src.cols, L)
    var s = _shrink3(src, f) if f > 1 else Mat[U8](copy=src)
    var n = s.rows * s.cols
    if s.rows < 8 or s.cols < 8:
        raise Error("subjectBox: image smaller than 8 px after the shrink")
    var g = gaussian_blur(cvt_color(s, 0), 5, 0.0)
    var sp = s.ptr()
    var gp = g.ptr()
    var t = Mat[U8](s.rows, s.cols, 1)
    for i in range(n):
        t.data[i] = 255 if _yellow(Int(sp[3 * i]), Int(sp[3 * i + 1]), Int(sp[3 * i + 2])) else 0
    var tc = components(t, 8)  # the tape is a long band across the frame; small yellow things (a gold strap) stay
    for i in range(n):
        var k = Int(tc[0].data[i])
        var lng = max(Int(tc[1].at(k, 2)), Int(tc[1].at(k, 3)))
        if k > 0 and (lng * 20 < 3 * max(s.rows, s.cols) or lng < 3 * min(Int(tc[1].at(k, 2)), Int(tc[1].at(k, 3)))):
            t.data[i] = 0
    t = morph[False, U8](t, 0, 2 * tape + 1, 1)  # dilate: the tape's soft edge goes too
    # hands: YCrCb skin range, opened, and only blobs of at least `skinshare` of the picture (a gold watch is skin-coloured too, but small)
    var sk = Mat[U8](s.rows, s.cols, 1)
    for i in range(n):
        var b = Float64(sp[3 * i])
        var gg = Float64(sp[3 * i + 1])
        var r = Float64(sp[3 * i + 2])
        var y = 0.299 * r + 0.587 * gg + 0.114 * b
        var cr = (r - y) * 0.713 + 128.0
        var cb = (b - y) * 0.564 + 128.0
        sk.data[i] = 255 if (t.data[i] == 0 and y >= 70.0 and cr >= 133.0 and cr <= 173.0 and cb >= 77.0 and cb <= 127.0) else 0
    sk = morph[False, U8](morph[True, U8](sk, 0, 19, 1), 0, 19, 1)  # 19 px: a bracelet is thinner than that, a palm is not
    var sc = components(sk, 8)
    var hand = Mat[U8](s.rows, s.cols, 1)
    for i in range(n):
        var k = Int(sc[0].data[i])
        if k > 0:  # a hand enters from the frame edge; a skin-coloured dial in the middle does not
            var l = Int(sc[1].at(k, 0))
            var t0 = Int(sc[1].at(k, 1))
            var edge = l == 0 or t0 == 0 or l + Int(sc[1].at(k, 2)) == s.cols or t0 + Int(sc[1].at(k, 3)) == s.rows
            var share = Float64(sc[1].at(k, 4)) / Float64(n)
            if (edge and share >= skinshare) or share >= 0.08:
                hand.data[i] = 255
    hand = morph[False, U8](hand, 0, 2 * tape + 1, 1)
    var hs = 0
    for i in range(n):
        if hand.data[i] != 0:
            t.data[i] = 255
            hs += 1
    var hshare = Float64(hs) / Float64(n)
    var hist = List[Int](length=256, fill=0)
    var m = 0
    for i in range(n):
        if t.data[i] == 0:
            hist[Int(gp[i])] += 1
            m += 1
    var none: List[Float64] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 99.0, hshare]
    if m == 0:
        return none^
    var med = _hist_pick(hist, m)
    var dh = List[Int](length=256, fill=0)
    for v in range(256):
        dh[abs(v - med)] += hist[v]
    var mad = Float64(_hist_pick(dh, m))
    none[6] = mad
    var thr = max(tmin, kmad * 1.4826 * mad)
    var fg = Mat[U8](s.rows, s.cols, 1)
    for i in range(n):
        fg.data[i] = 255 if (t.data[i] == 0 and Float64(abs(Int(gp[i]) - med)) > thr) else 0
    fg = morph[True, U8](morph[False, U8](fg, 0, 7, 1), 0, 7, 1)  # close
    fg = morph[False, U8](morph[True, U8](fg, 0, 3, 1), 0, 3, 1)  # open
    var cc = components(fg, 8)
    ref st = cc[1]
    ref cen = cc[2]
    # the subject is the region with the most area near the middle of the frame (centrality weight, sigma 0.3 of the
    # frame), plus every region of at least `keepfrac` of its area within 10 % of the long edge of the box so far
    var pick = 0
    var best = 0.0
    var total = 0
    for k in range(1, st.rows):
        var dx = cen.at(k, 0) / Float64(s.cols) - 0.5
        var dy = cen.at(k, 1) / Float64(s.rows) - 0.5
        var sc = Float64(st.at(k, 4)) * exp(-(dx * dx + dy * dy) / 0.18)
        total += Int(st.at(k, 4))
        if sc > best:
            best = sc
            pick = k
    if pick == 0 or Float64(st.at(pick, 4)) < minshare * Float64(n):
        return none^
    var x0 = Int(st.at(pick, 0))
    var y0 = Int(st.at(pick, 1))
    var x1 = x0 + Int(st.at(pick, 2))
    var y1 = y0 + Int(st.at(pick, 3))
    var gap = 0.10 * Float64(max(s.rows, s.cols))
    var used = List[Bool](length=st.rows, fill=False)
    used[pick] = True
    var grew = True
    while grew:
        grew = False
        for k in range(1, st.rows):
            var l = Int(st.at(k, 0))
            var t0 = Int(st.at(k, 1))
            var a = Float64(st.at(k, 4))
            if used[k] or a < keepfrac * Float64(st.at(pick, 4)) or a < minshare * Float64(n):
                continue
            if Float64(l) < Float64(x1) + gap and Float64(l + Int(st.at(k, 2))) > Float64(x0) - gap and Float64(t0) < Float64(y1) + gap and Float64(t0 + Int(st.at(k, 3))) > Float64(y0) - gap:
                used[k] = True
                grew = True
                x0 = min(x0, l)
                y0 = min(y0, t0)
                x1 = max(x1, l + Int(st.at(k, 2)))
                y1 = max(y1, t0 + Int(st.at(k, 3)))
    return [1.0, Float64(x0 * f), Float64(y0 * f), Float64(min(x1 * f, src.cols)), Float64(min(y1 * f, src.rows)), Float64(total) / Float64(n), mad, hshare]


def tape_scale(src: Mat[U8]) raises -> List[Float64]:
    """[px per cm in `src`, confidence] from the tape measure in the frame, [0, 0] when there is none. The tape is the
    largest long yellow band; the profile of the grey gradient along it is high-passed and autocorrelated: the 1 mm tick
    period pm is the strongest lag in 4..20 px (at the 1024 px analysis size), and 10 pm is refined to the 1 cm peak
    (numerals and long ticks) within 7 %, parabola-interpolated. Confidence = that peak's autocorrelation over lag 0."""
    var f = scale_factor(src.rows, src.cols, 1024)
    var s = _shrink3(src, f) if f > 1 else Mat[U8](copy=src)
    var n = s.rows * s.cols
    var sp = s.ptr()
    var y = Mat[U8](s.rows, s.cols, 1)
    for i in range(n):
        y.data[i] = 255 if _yellow(Int(sp[3 * i]), Int(sp[3 * i + 1]), Int(sp[3 * i + 2])) else 0
    y = morph[True, U8](morph[False, U8](y, 0, 9, 1), 0, 9, 1)
    var cc = components(y, 8)
    ref st = cc[1]
    var pick = 0
    for k in range(1, st.rows):
        if pick == 0 or st.at(k, 4) > st.at(pick, 4):
            pick = k
    var none: List[Float64] = [0.0, 0.0]
    if pick == 0:
        return none^
    var x0 = Int(st.at(pick, 0))
    var y0 = Int(st.at(pick, 1))
    var w = Int(st.at(pick, 2))
    var h = Int(st.at(pick, 3))
    var horiz = w >= h
    var lng = max(w, h)
    if lng * 5 < 2 * max(s.rows, s.cols) or lng < 4 * min(w, h):
        return none^
    var g = cvt_color(s, 0)
    var gp = g.ptr()
    var m = lng - 1
    var prof = List[Float64](length=m, fill=0.0)
    for t in range(m):
        var acc = 0.0
        if horiz:
            for yy in range(max(y0 - 4, 0), min(y0 + h + 4, s.rows)):
                acc += Float64(abs(Int(gp[yy * s.cols + x0 + t + 1]) - Int(gp[yy * s.cols + x0 + t])))
        else:
            for xx in range(max(x0 - 4, 0), min(x0 + w + 4, s.cols)):
                acc += Float64(abs(Int(gp[(y0 + t + 1) * s.cols + xx]) - Int(gp[(y0 + t) * s.cols + xx])))
        prof[t] = acc
    var hp = List[Float64](length=m, fill=0.0)  # minus a 61-sample moving average
    for t in range(m):
        var a0 = max(t - 30, 0)
        var a1 = min(t + 31, m)
        var sm = 0.0
        for j in range(a0, a1):
            sm += prof[j]
        hp[t] = prof[t] - sm / Float64(a1 - a0)
    var maxlag = min(m - 1, 230)
    var ac = List[Float64](length=maxlag + 1, fill=0.0)
    for l in range(maxlag + 1):
        var sm = 0.0
        for t in range(m - l):
            sm += hp[t] * hp[t + l]
        ac[l] = sm
    if ac[0] <= 0.0 or maxlag < 60:
        return none^
    var pm = 4
    for l in range(4, 21):
        if ac[l] > ac[pm]:
            pm = l
    var lo = Int(Float64(10 * pm) * 0.93)
    var hi = min(Int(Float64(10 * pm) * 1.07), maxlag - 1)
    if hi <= lo:
        return none^
    var cm = lo
    for l in range(lo, hi + 1):
        if ac[l] > ac[cm]:
            cm = l
    var off = 0.0
    var d = ac[cm - 1] - 2.0 * ac[cm] + ac[cm + 1]
    if d < 0.0:
        off = 0.5 * (ac[cm - 1] - ac[cm + 1]) / d
    return [(Float64(cm) + off) * Float64(f), ac[cm] / ac[0]]


def batch(mut a: Args) raises -> Bool:
    """stockPhoto OUT.jsonl BATCH.tsv [k=v]: BATCH.tsv rows are `decoded path <TAB> original path`. One JSON line per
    photo: {file,w,h,lapvar,tenengrad,lo,hi,box:[x0,y0,x1,y1] (null when empty),boxShare,fg,dhash,phash}. A line with
    "error" holds no numbers."""
    var paths = List[String]()
    var origs = List[String]()
    for r in open(a.ins[0], "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) >= 2:
            paths.append(String(f[0]))
            origs.append(String(f[1]))
    var n = len(paths)
    var asc = a.i("ascale", 1536)
    var lo = a.i("lo", 3)
    var hi = a.i("hi", 252)
    var L = a.i("boxscale", 256)
    var tape = a.i("tape", 6)
    var kmad = a.f("kmad", 4.0)
    var tmin = a.f("tmin", 25.0)
    var minshare = a.f("minshare", 0.003)
    var keepfrac = a.f("keepfrac", 0.04)
    var skinshare = a.f("skinshare", 0.015)
    comptime NV = 16
    var res = List[Float64](length=n * NV, fill=0.0)
    var hb = List[UInt8](length=n * 128, fill=0)
    var ef = List[Int](length=n, fill=0)
    var rp = res.unsafe_ptr()
    var hp = hb.unsafe_ptr()
    var ep = ef.unsafe_ptr()

    def task(i: Int) {imm}:
        try:
            var src = _load_any(paths[i])
            var g = cvt_color(src, 0)
            var f = scale_factor(g.rows, g.cols, asc)
            var ga = box_down(g, f) if f > 1 else Mat[U8](copy=g)
            var sh = sharpness(ga, 32, 10.0)
            var cl = clipping(ga, lo, hi)
            var bx = subject_box(src, L, tape, kmad, tmin, minshare, keepfrac, skinshare)
            var hh = hashes(g)
            var tp = tape_scale(src)
            var o = rp + i * NV
            o[14] = tp[0]
            o[15] = tp[1]
            o[0] = Float64(src.cols)
            o[1] = Float64(src.rows)
            o[2] = sh.data[0]
            o[3] = sh.data[1]
            o[4] = cl.data[0]
            o[5] = cl.data[1]
            for j in range(8):
                o[6 + j] = bx[j]
            for j in range(128):
                hp[i * 128 + j] = hh.data[j]
        except:
            ep[i] = 1

    par_dyn(task, n)
    _ = (len(res), len(hb), len(ef))
    var out = open(a.out, "w")
    for i in range(n):
        var line = String('{"file":"', _esc(origs[i]), '"')
        if ef[i] != 0:
            var why = String("analysis failed")
            try:
                _ = _load_any(paths[i])
            except e:
                why = String(e)
            line += String(',"error":"', _esc(why), '"}\n')
        else:
            var m = rp + i * NV
            line += String(',"w":', Int(m[0]), ',"h":', Int(m[1]), ',"lapvar":', _jn(m[2]), ',"tenengrad":', _jn(m[3]))
            line += String(',"lo":', _jn(m[4]), ',"hi":', _jn(m[5]))
            if m[6] > 0.5:
                var share = (m[9] - m[7]) * (m[10] - m[8]) / (m[0] * m[1])
                line += String(',"box":[', Int(m[7]), ",", Int(m[8]), ",", Int(m[9]), ",", Int(m[10]), '],"boxShare":', _jn(share))
            else:
                line += ',"box":null,"boxShare":0'
            line += String(',"tapePxCm":', _jn(m[14]) if m[14] > 0.0 else String("null"), ',"tapeConf":', _jn(m[15]))
            line += String(',"fg":', _jn(m[11]), ',"hand":', _jn(m[13]), ',"bgmad":', _jn(m[12]), ',"empty":', "true" if (m[6] < 0.5 and m[12] <= 10.0) else "false", ',"dhash":"', _hex(hb, i * 128), '","phash":"', _hex(hb, i * 128 + 64), '"}\n')
        out.write(line)
    _ = (len(res), len(hb), len(ef))
    return True


def run(mut a: Args) raises -> Bool:
    return batch(a) if a.op == "stockPhoto" else False
