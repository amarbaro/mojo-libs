# stockgroup: items, views and near-duplicates of a stock shoot from the time stamps, the SigLIP embeddings and the
# 64-bit dHash. `stockGroup OUT.tsv IN.tsv EMB.f32 [k=v]`; IN.tsv rows: name, t (s), lapvar, empty (0/1), dhash (hex).
#
# Item = the run of photos of one object. Consecutive photos (empty frames skipped) are scored by a logistic on
# z(log10(gap s + 0.5)) and z(embedding cosine); p > 0.5 is "same item". Weights fitted on the 193 consecutive pairs of
# the 194 watch and shoe photos of 2026-11-22 against the driver's 89 items (Sonnet vision + OCR labels, groups.json,
# so a measured agreement, not a ground truth): accuracy 0.912; a gap <= 25 s alone is also 0.912 (precision 0.91,
# recall 0.92), the cosine adds little there. An unsupervised two-component EM on the same pairs scored 0.881 and was
# dropped. Hard rules over the logistic: gap < `burst` (3 s) is the same item, gap > `maxgap` (600 s) is another.
# Front and back of one watch look different, so a view is not told by cosine alone: inside an item two photos are one
# view when cosine >= `vcos` (0.95: 4 % of the same-item pairs, the repeated shots) or dHash Hamming <= `vham` (6).
# The sharpest of a view by Laplacian variance is rank 0; the others name it in dup_of. Output TSV rows:
# name, group, view, view_rank, dup_of, gap, cos, p_same ("-" or -1 where none).
from std.math import log10, exp, sqrt
from std.bit import pop_count
from mojocv.core import Args


def _hex64(s: String) -> UInt64:
    var v: UInt64 = 0
    for c in s.codepoint_slices():
        var d = Int(ord(c))
        v = v * 16 + UInt64(d - 48 if d <= 57 else d - 87)
    return v


def _find(p: List[Int], i: Int) -> Int:
    var r = i
    while p[r] != r:
        r = p[r]
    return r


def group(mut a: Args) raises -> Bool:
    var names = List[String]()
    var ts = List[Float64]()
    var lap = List[Float64]()
    var empty = List[Bool]()
    var dh = List[UInt64]()
    for r in open(a.ins[0], "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) < 5:
            continue
        names.append(String(f[0]))
        ts.append(atof(String(f[1])))
        lap.append(atof(String(f[2])))
        empty.append(String(f[3]) == "1")
        dh.append(_hex64(String(f[4])))
    var n = len(names)
    var eb = open(a.ins[1], "r").read_bytes()
    if n == 0 or len(eb) != n * 768 * 4:
        raise Error("stockGroup: " + String(len(eb)) + " embedding bytes for " + String(n) + " photos (want 768 float32 each)")
    var ep = eb.unsafe_ptr().bitcast[Float32]()
    var emb = List[Float64](length=n * 768, fill=0.0)
    for i in range(n):
        var s = 0.0
        for j in range(768):
            s += Float64(ep[i * 768 + j]) ** 2
        s = sqrt(s) if s > 0.0 else 1.0
        for j in range(768):
            emb[i * 768 + j] = Float64(ep[i * 768 + j]) / s
    _ = len(eb)
    var burst = a.f("burst", 3.0)
    var maxgap = a.f("maxgap", 600.0)
    var vcos = a.f("vcos", 0.95)
    var vham = a.i("vham", 6)
    var gmu = a.f("gmu", 1.48)
    var gsd = a.f("gsd", 0.544)
    var cmu = a.f("cmu", 0.792)
    var csd = a.f("csd", 0.099)
    var wg = a.f("wg", -2.73)
    var wc = a.f("wc", 1.05)
    var bias = a.f("bias", -0.28)
    # active photos in time order (insertion sort: n is a few hundred)
    var act = List[Int]()
    for i in range(n):
        if not empty[i]:
            act.append(i)
    for i in range(1, len(act)):
        var k = act[i]
        var j = i - 1
        while j >= 0 and ts[act[j]] > ts[k]:
            act[j + 1] = act[j]
            j -= 1
        act[j + 1] = k
    var gap = List[Float64](length=n, fill=-1.0)
    var cs = List[Float64](length=n, fill=-1.0)
    var ps = List[Float64](length=n, fill=-1.0)
    var grp = List[Int](length=n, fill=-1)
    var g = -1
    for p in range(len(act)):
        var same = False
        if p > 0:
            var u = act[p - 1]
            var v = act[p]
            var c = 0.0
            for j in range(768):
                c += emb[u * 768 + j] * emb[v * 768 + j]
            gap[v] = ts[v] - ts[u]
            cs[v] = c
            var z = bias + wg * (log10(max(gap[v], 0.0) + 0.5) - gmu) / gsd + wc * (c - cmu) / csd
            ps[v] = 1.0 / (1.0 + exp(-z))
            same = (ps[v] > 0.5 or gap[v] < burst) and gap[v] <= maxgap
        if not same:
            g += 1
        grp[act[p]] = g
    # views: union inside an item by cosine or hash
    var par = List[Int](length=n, fill=0)
    for i in range(n):
        par[i] = i
    for i in range(n):
        for k in range(i + 1, n):
            if grp[i] < 0 or grp[i] != grp[k]:
                continue
            var c = 0.0
            for j in range(768):
                c += emb[i * 768 + j] * emb[k * 768 + j]
            if c >= vcos or Int(pop_count(dh[i] ^ dh[k])) <= vham:
                par[_find(par, i)] = _find(par, k)
    var best = List[Int](length=n, fill=-1)
    for i in range(n):
        if grp[i] >= 0:
            var r = _find(par, i)
            if best[r] < 0 or lap[i] > lap[best[r]]:
                best[r] = i
    var out = open(a.out, "w")
    for i in range(n):
        var line = String(names[i], "\t", grp[i])
        if grp[i] < 0:
            out.write(line + "\t-1\t-1\t-\t-1\t-1\t-1\n")
            continue
        var r = _find(par, i)
        var rank = 0
        for k in range(n):
            if grp[k] == grp[i] and _find(par, k) == r and (lap[k] > lap[i] or (lap[k] == lap[i] and k < i)):
                rank += 1
        var vi = 0  # view number = distinct views of the item that start earlier in time
        var seen = List[Int]()
        for p in range(len(act)):
            var k = act[p]
            if grp[k] != grp[i]:
                continue
            var rk = _find(par, k)
            if rk == r:
                break
            if rk not in seen:
                seen.append(rk)
                vi += 1
        out.write(line + String("\t", vi, "\t", rank, "\t", "-" if rank == 0 else names[best[r]], "\t", gap[i], "\t", cs[i], "\t", ps[i], "\n"))
    print("stockGroup:", g + 1, "items from", len(act), "photos,", n - len(act), "empty frames")
    _ = (len(emb), len(par))
    return True


def run(mut a: Args) raises -> Bool:
    return group(a) if a.op == "stockGroup" else False
