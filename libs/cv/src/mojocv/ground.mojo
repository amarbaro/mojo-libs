# ground: instruction plus element list to a target or an abstention (plan R21a, the matching baseline; no learned grounder).
#   ground OUT elems=FILE qs=Q1|Q2|... [w= h= dx= dy= rows= thr= margin=]
# FILE is the element table of tests/fixtures/fs-h5 and of `elements` after jq: a header row, then tab separated
#   idx class text desc clickable x1 y1 x2 y2    (boxes in display pixels). Queries are separated by | and use _ for a space.
# OUT float64, one row per query: [idx, score, margin, abstain, cx, cy, stale]; idx and cx, cy are -1 on an abstention.
# Score: Dice overlap 2|Q & L| / (|Q| + |L|) of the query tokens with the label tokens (text and desc of the element). Tokens are runs
#   of A-Z a-z 0-9 and of every byte >= 128; ASCII letters are lowered, other letters are not folded. Query words click, tap, press,
#   push, select, open, on, the, a, an, to, button, icon, link, field, tab, menu, please, then, and are dropped.
# Target: the best score; ties go to a clickable element, then the smaller box, then the lower idx. Margin: best minus the best score of
#   any element that is not nested with the target (one box inside the other: a clickable parent and its text child are one target).
# Abstain when the best score < thr (0.5), the margin < margin (0.05), the query has no content word, or the geometry is stale.
# Stale: with w and h given, any element box (shifted by dx, dy: a known scroll or origin) outside [0,w] x [0,h]. rows=N reads only the
#   first N elements (rows=0 is a blank screen). UI text is data: it is compared, never executed or followed.
# Not claimed: accuracy on ScreenSpot (data not on disk, licence UNVERIFIED). The fs-ground rows measure token matching against
#   instructions derived from the element labels of two real phone screens.
from mojocv.mat import Mat, save
from mojocv.core import Args

comptime F64 = DType.float64
comptime STOP = " click tap press push select open on the a an to button icon link field tab menu please then and "


def _tokens(s: String, drop: Bool) -> List[String]:
    var out = List[String]()
    var cur = String()
    var n = s.byte_length()
    var i = 0
    for c in s.codepoint_slices():
        var cp = Int(ord(c))
        var keep = (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 122) or (cp >= 65 and cp <= 90) or cp >= 128
        if keep:
            cur += chr(cp + 32) if (cp >= 65 and cp <= 90) else String(c)
        if (not keep or i + c.byte_length() == n) and cur.byte_length() > 0:
            if not (drop and (" " + cur + " ") in STOP) and cur not in out:
                out.append(cur)
            cur = String()
        i += c.byte_length()
    return out^


def _dice(q: List[String], l: List[String]) -> Float64:
    if len(q) == 0 or len(l) == 0:
        return 0.0
    var c = 0
    for t in q:
        if t in l:
            c += 1
    return 2.0 * Float64(c) / Float64(len(q) + len(l))


def ground(mut a: Args) raises -> Bool:
    var labels = List[List[String]]()
    var bx = List[Int]()  # x1 y1 x2 y2 per element
    var click = List[Bool]()
    var maxn = a.i("rows", 1 << 30)
    var dx = a.i("dx", 0)
    var dy = a.i("dy", 0)
    for r in open(a.s("elems", ""), "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) < 9 or String(f[0]) == "idx" or len(labels) >= maxn:
            continue
        labels.append(_tokens(String(f[2]) + " " + String(f[3]), False))
        click.append(String(f[4]) == "true")
        for k in range(5, 9):
            bx.append(Int(atof(String(f[k]))))
    var n = len(labels)
    var w = a.i("w", 0)
    var h = a.i("h", 0)
    var stale = False
    for e in range(n):
        if w > 0 and h > 0 and (bx[4 * e] + dx < 0 or bx[4 * e + 1] + dy < 0 or bx[4 * e + 2] + dx > w or bx[4 * e + 3] + dy > h):
            stale = True
    var thr = a.f("thr", 0.5)
    var mmin = a.f("margin", 0.05)
    var qs = a.s("qs", "").split("|")
    var o = Mat[F64](len(qs), 7, 1, False)
    for qi in range(len(qs)):
        var qt = _tokens(String(qs[qi]), True)
        var sc = List[Float64](length=n, fill=0.0)
        var best = 0.0
        for e in range(n):
            sc[e] = _dice(qt, labels[e])
            best = max(best, sc[e])
        var sel = -1
        for e in range(n):
            if best > 0.0 and sc[e] == best:
                var better = sel < 0
                if sel >= 0:
                    var ar = (bx[4 * e + 2] - bx[4 * e]) * (bx[4 * e + 3] - bx[4 * e + 1])
                    var as_ = (bx[4 * sel + 2] - bx[4 * sel]) * (bx[4 * sel + 3] - bx[4 * sel + 1])
                    better = (click[e] and not click[sel]) or (click[e] == click[sel] and ar < as_)
                if better:
                    sel = e
        var second = 0.0
        for e in range(n):
            if sel < 0 or e == sel:
                continue
            var in1 = bx[4 * e] >= bx[4 * sel] and bx[4 * e + 1] >= bx[4 * sel + 1] and bx[4 * e + 2] <= bx[4 * sel + 2] and bx[4 * e + 3] <= bx[4 * sel + 3]
            var in2 = bx[4 * sel] >= bx[4 * e] and bx[4 * sel + 1] >= bx[4 * e + 1] and bx[4 * sel + 2] <= bx[4 * e + 2] and bx[4 * sel + 3] <= bx[4 * e + 3]
            if not (in1 or in2):
                second = max(second, sc[e])
        var margin = best - second
        var abst = sel < 0 or best < thr or margin < mmin or stale
        o.data[7 * qi] = -1.0 if abst else Float64(sel)
        o.data[7 * qi + 1] = best
        o.data[7 * qi + 2] = margin if sel >= 0 else 0.0
        o.data[7 * qi + 3] = 1.0 if abst else 0.0
        o.data[7 * qi + 4] = -1.0 if abst else Float64(bx[4 * sel] + bx[4 * sel + 2] + 2 * dx) / 2.0
        o.data[7 * qi + 5] = -1.0 if abst else Float64(bx[4 * sel + 1] + bx[4 * sel + 3] + 2 * dy) / 2.0
        o.data[7 * qi + 6] = 1.0 if stale else 0.0
    save(o, a.out)
    return True


def run(mut a: Args) raises -> Bool:
    return ground(a) if a.op == "ground" else False
