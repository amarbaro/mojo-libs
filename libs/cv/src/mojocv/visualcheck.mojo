# visualcheck: per-picture signals that tell a real object from "just a shape". The stock checks (blank, blur, cast) pass a
# grey box that is sharp and well exposed; these look at what the box lacks: colour variety on the object, detail inside
# the silhouette, a silhouette that is more than a few straight edges, and large areas of one flat shade.
# The object mask is "what departs from the backdrop": the backdrop colour is the per-channel median of the image border,
# and a picture whose border is not uniform (a photo, a texture) is treated as all object. Texture is measured inside the
# mask eroded by 2 px, so the silhouette edge itself never counts as detail, on a gamma-lifted luma (x^0.45: lstd, hf, hfshare, flat,
# lf, ent, edge, lapq) so a dark render is judged like a bright one. All numbers come from the picture shrunk
# (area mean) to a long edge near `scale` (default 384), so a 512 px view and a 6000 px render are compared alike.
from std.math import sqrt, log, exp
from mojocv.mat import Mat
from mojocv.core import Args, par_dyn
from mojocv.imgproc import find_contours, morph
from mojocv.calib3d import approx_poly
from mojocv.stockcheck import scale_factor, _load_any, _esc, _jn
from mojocv.stockphoto import _shrink3
from mojocv.texdefect import defects

comptime U8 = DType.uint8
comptime NV = 28
comptime PI = 3.141592653589793

# signal slots, in the order the JSON keys are written (the list in `batch`)
comptime K_W = 0
comptime K_H = 1
comptime K_FILL = 2  # object share of the picture
comptime K_BGBAD = 3  # share of border pixels that depart from the backdrop colour (0 = clean backdrop)
comptime K_CHROMA = 4  # mean max-min channel spread on the object, 0..255
comptime K_CHP90 = 5  # 90th percentile of that spread
comptime K_CHSTD = 6  # its standard deviation: colour spread across the object
comptime K_PALETTE = 7  # 3-bit-per-channel colour buckets holding >= 0.5 % of the object
comptime K_HUEN = 8  # of 12 hue bins, those holding >= 3 % of the coloured pixels
comptime K_LSTD = 9  # luma standard deviation on the object
comptime K_HF = 10  # mean |Laplacian| / 4 inside the eroded mask (grey levels)
comptime K_HFSHARE = 11  # share of inner pixels with |4c - n - s - e - w| >= 6
comptime K_FLAT = 12  # share of inner pixels whose 5-point luma range is <= 2 (one flat shade or a smooth gradient)
comptime K_LF = 13  # std of 8x8 block means inside the mask: blotches and large patterns
comptime K_COMPLEX = 14  # contour length^2 / (4 pi area): 1 for a disc, 1.27 a square
comptime K_SOLID = 15  # contour area / convex hull area
comptime K_CORNERS = 16  # Douglas-Peucker vertices of the contour at 2 % of its length
comptime K_PRIM = 17  # flat-shaded primitive score, 0..1
comptime K_INNER = 18  # inner mask pixel count
comptime K_EMPTY = 19  # 1 when no object was found
comptime K_COMPS = 20  # outer contours of 20 px or more
comptime K_SAT = 21  # mean saturation (spread / max) on the object
comptime K_ENT = 22  # entropy (bits, 64 bins) of the lifted luma on the object: shading ramps and patterns spread it
comptime K_EDGE = 23  # share of inner pixels with |dx| + |dy| >= 12 (central differences): panel lines, grain, decals
comptime K_LAPQ = 24  # share of inner pixels with |4c - n - s - e - w| >= 24: strong local detail
comptime K_BLANK = 25  # share of the object (mask eroded 4 px) that is near-uniform light grey or white, shading divided out (texdefect)
comptime K_SEAM = 26  # straight textured/blank boundary length inside the object, in units of sqrt(object area) (texdefect)
comptime K_STRETCH = 27  # 0..1 coherence of the fine texture along one direction (texdefect)


def _bgr(src: Mat[U8]) raises -> Mat[U8]:
    if src.ch == 3:
        return Mat[U8](copy=src)
    if src.ch != 1 and src.ch != 4:
        raise Error("visualcheck: " + String(src.ch) + " channels")
    var o = Mat[U8](src.rows, src.cols, 3, False)
    var p = src.ptr()
    var q = o.ptr()
    for i in range(src.rows * src.cols):
        for k in range(3):
            q[3 * i + k] = p[i] if src.ch == 1 else p[4 * i + k]
    return o^


def _clamp01(v: Float64) -> Float64:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def _median(h: List[Int], n: Int) -> Int:
    var acc = 0
    for v in range(256):
        acc += h[v]
        if 2 * acc >= n:
            return v
    return 255


def _hull_area(px: List[Int], py: List[Int]) -> Float64:
    """Convex hull area by gift wrapping (a contour at long edge 384 holds under 1500 points)."""
    var n = len(px)
    if n < 3:
        return 0.0
    var s = 0
    for i in range(n):
        if px[i] < px[s] or (px[i] == px[s] and py[i] < py[s]):
            s = i
    var hx = List[Int]()
    var hy = List[Int]()
    var p = s
    for _ in range(n + 1):
        hx.append(px[p])
        hy.append(py[p])
        var c = (p + 1) % n
        for i in range(n):
            var cr = (px[c] - px[p]) * (py[i] - py[p]) - (py[c] - py[p]) * (px[i] - px[p])
            var di = (px[i] - px[p]) ** 2 + (py[i] - py[p]) ** 2
            var dc = (px[c] - px[p]) ** 2 + (py[c] - py[p]) ** 2
            if cr < 0 or (cr == 0 and di > dc):
                c = i
        p = c
        if p == s:
            break
    var m = len(hx)
    var a = 0
    for i in range(m):
        var j = (i + 1) % m
        a += hx[i] * hy[j] - hx[j] * hy[i]
    return Float64(abs(a)) * 0.5


def _analyse(src: Mat[U8], L: Int, thr: Int) raises -> List[Float64]:
    var o = List[Float64](length=NV, fill=0.0)
    o[K_W] = Float64(src.cols)
    o[K_H] = Float64(src.rows)
    var f = scale_factor(src.rows, src.cols, L)
    var s = _shrink3(_bgr(src), f)
    var R = s.rows
    var C = s.cols
    if R < 16 or C < 16:
        raise Error("visualcheck: picture too small")
    var p = s.ptr()
    # backdrop colour: per-channel median of the 2 px border ring
    var hist = List[Int](length=768, fill=0)
    var nb = 0
    for y in range(R):
        for x in range(C):
            if y < 2 or y >= R - 2 or x < 2 or x >= C - 2:
                nb += 1
                for k in range(3):
                    hist[256 * k + Int(p[(y * C + x) * 3 + k])] += 1
    var bg = List[Int](length=3, fill=0)
    for k in range(3):
        var hk = List[Int](length=256, fill=0)
        for v in range(256):
            hk[v] = hist[256 * k + v]
        bg[k] = _median(hk, nb)
    var bad = 0
    for y in range(R):
        for x in range(C):
            if y < 2 or y >= R - 2 or x < 2 or x >= C - 2:
                var d = 0
                for k in range(3):
                    d = max(d, abs(Int(p[(y * C + x) * 3 + k]) - bg[k]))
                if d > thr:
                    bad += 1
    o[K_BGBAD] = Float64(bad) / Float64(nb)
    var photo = o[K_BGBAD] > 0.25
    var mask = Mat[U8](R, C, 1, False)
    var mp = mask.ptr()
    var cnt = 0
    for i in range(R * C):
        var d = 0
        for k in range(3):
            d = max(d, abs(Int(p[i * 3 + k]) - bg[k]))
        var on = photo or d > thr
        mp[i] = 255 if on else 0
        if on:
            cnt += 1
    o[K_FILL] = Float64(cnt) / Float64(R * C)
    if cnt < max(16, (R * C) // 500):
        o[K_EMPTY] = 1.0
        return o^
    var inner = morph[True, U8](mask, 0, 5, 1)
    var ip = inner.ptr()
    # luma, gamma-lifted (x^0.45) so detail on a dark render counts as much as on a bright one
    var lut = List[Int16](length=256, fill=0)
    for v in range(256):
        lut[v] = Int16(Int(255.0 * (Float64(v) / 255.0) ** 0.45 + 0.5))
    var lum = List[Int16](length=R * C, fill=0)
    for i in range(R * C):
        lum[i] = lut[(29 * Int(p[i * 3]) + 150 * Int(p[i * 3 + 1]) + 77 * Int(p[i * 3 + 2])) >> 8]
    var lp = lum.unsafe_ptr()
    # colour and detail statistics on the inner mask (the object body without its antialiased rim)
    var ch = List[Int](length=256, fill=0)
    var pal = List[Int](length=512, fill=0)
    var hue = List[Int](length=12, fill=0)
    var n_in = 0
    var n_col = 0
    var csum = 0.0
    var c2 = 0.0
    var satsum = 0.0
    var lsum = 0.0
    var l2 = 0.0
    var hfsum = 0.0
    var hfn = 0
    var hfs = 0
    var flat = 0
    var edge = 0
    var lapq = 0
    var lh = List[Int](length=64, fill=0)
    var bs = 8
    var bw = C // bs
    var bh = R // bs
    var bsum = List[Float64](length=bw * bh, fill=0.0)
    var bcnt = List[Int](length=bw * bh, fill=0)
    var binn = List[Int](length=bw * bh, fill=0)
    for y in range(R):
        for x in range(C):
            var i = y * C + x
            if y // bs < bh and x // bs < bw:
                var bi = (y // bs) * bw + x // bs
                bcnt[bi] += 1
                if ip[i] != 0:
                    binn[bi] += 1
                    bsum[bi] += Float64(lp[i])
            if ip[i] == 0:
                continue
            n_in += 1
            var b = Int(p[i * 3])
            var g = Int(p[i * 3 + 1])
            var r = Int(p[i * 3 + 2])
            var mx = max(b, max(g, r))
            var mn = min(b, min(g, r))
            var cc = mx - mn
            ch[cc] += 1
            csum += Float64(cc)
            c2 += Float64(cc * cc)
            satsum += Float64(cc) / Float64(max(mx, 1))
            pal[(b >> 5) * 64 + (g >> 5) * 8 + (r >> 5)] += 1
            if cc >= 24:
                n_col += 1
                var fcc = Float64(cc)
                var h6 = 0.0
                if mx == r:
                    h6 = Float64(g - b) / fcc
                    if h6 < 0.0:
                        h6 += 6.0
                elif mx == g:
                    h6 = Float64(b - r) / fcc + 2.0
                else:
                    h6 = Float64(r - g) / fcc + 4.0
                hue[min(11, Int(h6 * 2.0))] += 1
            var l = Float64(lp[i])
            lsum += l
            l2 += l * l
            lh[Int(lp[i]) >> 2] += 1
            if y >= 1 and y < R - 1 and x >= 1 and x < C - 1:
                var lc = Int(lp[i])
                var ln = Int(lp[i - C])
                var ls = Int(lp[i + C])
                var le = Int(lp[i + 1])
                var lw = Int(lp[i - 1])
                var lap = abs(4 * lc - ln - ls - le - lw)
                hfn += 1
                hfsum += Float64(lap) / 4.0
                if lap >= 6:
                    hfs += 1
                if lap >= 24:
                    lapq += 1
                if abs(le - lw) + abs(ls - ln) >= 12:
                    edge += 1
                var hi = max(lc, max(max(ln, ls), max(le, lw)))
                var lo = min(lc, min(min(ln, ls), min(le, lw)))
                if hi - lo <= 2:
                    flat += 1
    if n_in < 16 or hfn < 16:
        o[K_EMPTY] = 1.0
        return o^
    var nf = Float64(n_in)
    o[K_INNER] = nf
    o[K_CHROMA] = csum / nf
    o[K_CHSTD] = sqrt(max(0.0, c2 / nf - (csum / nf) ** 2))
    o[K_SAT] = satsum / nf
    var acc = 0
    for v in range(256):
        acc += ch[v]
        if Float64(acc) >= 0.9 * nf:
            o[K_CHP90] = Float64(v)
            break
    var pn = 0
    for v in range(512):
        if Float64(pal[v]) >= 0.005 * nf:
            pn += 1
    o[K_PALETTE] = Float64(pn)
    var hn = 0
    for v in range(12):
        if n_col > 0 and Float64(hue[v]) >= 0.03 * Float64(n_col):
            hn += 1
    o[K_HUEN] = Float64(hn)
    o[K_LSTD] = sqrt(max(0.0, l2 / nf - (lsum / nf) ** 2))
    o[K_HF] = hfsum / Float64(hfn)
    o[K_HFSHARE] = Float64(hfs) / Float64(hfn)
    o[K_FLAT] = Float64(flat) / Float64(hfn)
    o[K_EDGE] = Float64(edge) / Float64(hfn)
    o[K_LAPQ] = Float64(lapq) / Float64(hfn)
    var ent = 0.0
    for v in range(64):
        if lh[v] > 0:
            var q = Float64(lh[v]) / nf
            ent -= q * log(q) / 0.6931471805599453
    o[K_ENT] = ent
    var nbk = 0
    var bm = 0.0
    var b2 = 0.0
    for i in range(bw * bh):
        if bcnt[i] > 0 and binn[i] == bcnt[i]:
            var m = bsum[i] / Float64(bcnt[i])
            nbk += 1
            bm += m
            b2 += m * m
    if nbk >= 4:
        o[K_LF] = sqrt(max(0.0, b2 / Float64(nbk) - (bm / Float64(nbk)) ** 2))
    # silhouette: the longest outer contour of the whole mask
    var cr = find_contours(mask, 0, True)
    var pts = cr[0].ptr()
    var lens = cr[1].ptr()
    var best = -1
    var bl = 0
    var at = 0
    var bat = 0
    var comps = 0
    for k in range(cr[1].rows):
        var ln = Int(lens[k])
        if ln >= 20:
            comps += 1
        if ln > bl:
            bl = ln
            best = k
            bat = at
        at += ln
    o[K_COMPS] = Float64(comps)
    if best >= 0 and bl >= 8:
        var px = List[Int]()
        var py = List[Int]()
        for j in range(bl):
            px.append(Int(pts[2 * (bat + j)]))
            py.append(Int(pts[2 * (bat + j) + 1]))
        var per = 0.0
        var a2 = 0
        for j in range(bl):
            var k2 = (j + 1) % bl
            per += sqrt(Float64((px[j] - px[k2]) ** 2 + (py[j] - py[k2]) ** 2))
            a2 += px[j] * py[k2] - px[k2] * py[j]
        var area = max(Float64(abs(a2)) * 0.5, 1.0)
        o[K_COMPLEX] = per * per / (4.0 * PI * area)
        var ha = _hull_area(px, py)
        o[K_SOLID] = min(1.0, area / ha) if ha > 0.0 else 1.0
        o[K_CORNERS] = Float64(len(approx_poly(px, py, 0.02 * per)))
    # flat-shaded primitive: large flat areas, few colour buckets, no fine detail, a plain outline. Soft terms, geometric mean.
    var ta = _clamp01((o[K_FLAT] - 0.55) / 0.35)
    var tb = _clamp01((10.0 - o[K_PALETTE]) / 7.0)
    var tc = _clamp01(1.0 - o[K_HFSHARE] / 0.25)
    var td = 0.5 * _clamp01((2.5 - o[K_COMPLEX]) / 1.5) + 0.5 * _clamp01((o[K_SOLID] - 0.8) / 0.2)
    o[K_PRIM] = sqrt(sqrt(ta * tb * tc * td))
    var dfx = defects(s, lum, mask, inner)
    o[K_BLANK] = dfx[0]
    o[K_SEAM] = dfx[1]
    o[K_STRETCH] = dfx[2]
    return o^


def _judge(kind: String, o: List[Float64], bad_cut: Float64, ok_cut: Float64) -> Tuple[Float64, String, String]:
    """(score 0..100, verdict ok|weak|bad, reason). 3D `view` and `preview` pictures: score = 100 * P(good) of a logistic model on
    standardised saturation, inner-edge share and flat share (the weights are monotone: colour and detail never lower the score).
    Fit by tools/visual-fit.sh in AssetsHQ on the 2026-11-28 labels (bad: low-poly store pack members under 2000 triangles; good: 3D
    assets with over 20000 triangles and a texture of 1024 px or more) on the half of the labelled set whose sha256 starts with 0-7.
    `preview` is the 200 px store preview (grey backdrop, clay look), `view` the 512 px ortho sheet of asset-check (black backdrop).
    bad under bad_cut, ok from ok_cut; the reason names the signal that pulls the score down most. `image`, `texture` and `frame`
    have no labels: fixed rules for a blank or near-uniform picture (score 0 bad, 40 weak, 100 ok)."""
    if o[K_EMPTY] > 0.5:
        return (0.0, String("bad"), String("blank: no object on the backdrop"))
    if kind == "view" or kind == "preview":
        var pv = kind == "preview"
        var mu: List[Float64] = [0.12065, 0.15533, 0.66260] if pv else [0.24087, 0.14166, 0.52697]
        var sd: List[Float64] = [0.15978, 0.18296, 0.26417] if pv else [0.15620, 0.13538, 0.29103]
        var w: List[Float64] = [0.9231, 0.6002, -1.4699] if pv else [0.0937, 0.8573, 0.0]
        var x: List[Float64] = [o[K_SAT], o[K_EDGE], o[K_FLAT]]
        var names: List[String] = ["sat", "edge", "flat"]
        var a = -1.0294 if pv else -0.0770
        var worst = 0
        var wc = 0.0
        for j in range(3):
            var c = w[j] * (x[j] - mu[j]) / sd[j]
            a += c
            if c < wc:
                wc = c
                worst = j
        var score = 100.0 / (1.0 + exp(-a))
        var v = String("bad") if score < bad_cut else (String("ok") if score >= ok_cut else String("weak"))
        var why = String()
        if v != "ok":
            why = String(names[worst], "=", round(x[worst], 3), " sat=", round(o[K_SAT], 3), " edge=", round(o[K_EDGE], 3), " flat=", round(o[K_FLAT], 3))
        return (score, v^, why^)
    var u = o[K_LSTD]
    var lo = 1.0 if kind == "texture" else (4.0 if kind == "frame" else 3.0)
    var mid = 3.0 if kind == "texture" else (12.0 if kind == "frame" else 8.0)
    if u < lo or o[K_FLAT] > 0.985:
        return (0.0, String("bad"), String("uniform: luma std ", round(u, 2), " flat ", round(o[K_FLAT], 3)))
    if u < mid or (kind != "texture" and o[K_FLAT] > 0.95) or (kind == "image" and o[K_PALETTE] <= 3.0 and o[K_HFSHARE] < 0.05):
        return (40.0, String("weak"), String("near-uniform: luma std ", round(u, 2), " flat ", round(o[K_FLAT], 3), " palette ", Int(o[K_PALETTE])))
    return (100.0, String("ok"), String())


def batch(mut a: Args) raises -> Bool:
    """visualCheck OUT.jsonl BATCH.tsv [scale=384 thr=14 badcut=40|45 okcut=60]: BATCH.tsv rows are `decoded path <TAB> original path <TAB> kind`
    (kind view|preview|image|texture|frame). One JSON line per picture: {file,kind,w,h,fill,...,score,verdict,reason}. A line with
    "error" holds no numbers."""
    var keys: List[String] = ["w", "h", "fill", "bgbad", "chroma", "chp90", "chstd", "palette", "huen", "lstd", "hf", "hfshare", "flat", "lf", "complex", "solid", "corners", "prim", "inner", "empty", "comps", "sat", "ent", "edge", "lapq", "blank", "seam", "stretch"]
    var paths = List[String]()
    var origs = List[String]()
    var kinds = List[String]()
    for r in open(a.ins[0], "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) >= 2:
            paths.append(String(f[0]))
            origs.append(String(f[1]))
            kinds.append(String(f[2]) if len(f) > 2 else String("image"))
    var n = len(paths)
    var L = a.i("scale", 384)
    var thr = a.i("thr", 14)
    var bad_cut = a.f("badcut", -1.0)  # default 40 on a preview, 45 on a view (test-half precision/recall in docs/visualcheck.md)
    var ok_cut = a.f("okcut", 60.0)
    var res = List[Float64](length=n * NV, fill=0.0)
    var ef = List[Int](length=n, fill=0)
    var rp = res.unsafe_ptr()
    var ep = ef.unsafe_ptr()

    def task(i: Int) {imm}:
        try:
            var v = _analyse(_load_any(paths[i]), L, thr)
            for j in range(NV):
                rp[i * NV + j] = v[j]
        except:
            ep[i] = 1

    par_dyn(task, n)
    _ = (len(res), len(ef))
    var out = open(a.out, "w")
    for i in range(n):
        var line = String('{"file":"', _esc(origs[i]), '","kind":"', kinds[i], '"')
        if ef[i] != 0:
            var why = String("analysis failed")
            try:
                _ = _analyse(_load_any(paths[i]), L, thr)
            except e:
                why = String(e)
            line += String(',"error":"', _esc(why), '"}\n')
        else:
            var o = List[Float64](length=NV, fill=0.0)
            for j in range(NV):
                o[j] = res[i * NV + j]
                line += String(',"', keys[j], '":', _jn(o[j]))
            var bc = bad_cut if bad_cut >= 0.0 else (40.0 if kinds[i] == "preview" else 45.0)
            var jd = _judge(kinds[i], o, bc, ok_cut)
            line += String(',"score":', round(jd[0], 1), ',"verdict":"', jd[1], '","reason":"', _esc(jd[2]), '"}\n')
        out.write(line)
    return True


def run(mut a: Args) raises -> Bool:
    return batch(a) if a.op == "visualCheck" else False
