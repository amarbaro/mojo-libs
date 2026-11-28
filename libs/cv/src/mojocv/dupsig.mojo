# dupsig: duplicate signatures of 3D assets from their fitted ortho view picture and the geometry numbers.
# `viewSig OUT.tsv BATCH.tsv [scale=256 thr=30]` writes, per picture, the shape of the object and nothing that a re-colour changes:
# the aspect of the object's bounding box, its mean colour (kept apart, it only tells a colour variant from a twin), a G x G grid of
# object coverage over that box (the silhouette, scale and position free) and a G x G grid of luma divided by the object's mean luma
# (shading and pattern structure, brightness free). The object is "what departs from the backdrop": the per-channel median of the
# 2 px border, summed absolute difference >= thr.
# `sigPairs OUT.tsv IN.tsv [iou=.985 shade=8 dim=.15 asp=.15 gtol=.02 giou=.6 lou=.85 lsh=15 ldim=.05 lcd=30]` lists every pair of rows
# of IN.tsv that are one model:
#   view  silhouette IoU >= iou, box aspect within asp, shading difference <= shade, sorted bbox dims within dim (a re-export, a
#         LOD or a re-colour of one mesh: the triangle count is free)
#   geo   triangles and vertices within gtol, bbox dims within gtol after dividing by the longest, same texture count and size
#         (the unit and the axes are free); when both rows have a picture the silhouette IoU must still reach giou
#   look  the looser sheet match of one generator recipe (a regenerated bench or apple differs by a few percent of silhouette):
#         IoU >= lou, shading <= lsh, dims and aspect within ldim, same texture count and size, mean colour within lcd (RGB)
# IN.tsv rows: id tris verts bx by bz textures texpx aspect r g b occ shade (picture columns "-" where there is none).
# OUT.tsv rows: id_a id_b rule iou shade aspect_ratio colour_distance.
from mojocv.mat import Mat
from mojocv.core import Args, par_dyn
from mojocv.stockcheck import scale_factor, _load_any, _esc
from mojocv.stockphoto import _shrink3
from mojocv.visualcheck import _bgr, _median

comptime U8 = DType.uint8
comptime G = 24  # grid cells per side
comptime NG = G * G
comptime HEX = "0123456789abcdef"


def _sig(src: Mat[U8], L: Int, thr: Int) raises -> List[Float64]:
    """[found, aspect, r, g, b] then NG coverage cells (0..255) then NG shading cells (0..255)."""
    var o = List[Float64](length=5 + 2 * NG, fill=0.0)
    var s = _shrink3(_bgr(src), scale_factor(src.rows, src.cols, L))
    var R = s.rows
    var C = s.cols
    if R < 16 or C < 16:
        raise Error("dupsig: picture too small")
    var p = s.ptr()
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
    var m = List[UInt8](length=R * C, fill=0)
    var x0 = C
    var x1 = -1
    var y0 = R
    var y1 = -1
    var cnt = 0
    var sb = 0
    var sg = 0
    var sr = 0
    for y in range(R):
        for x in range(C):
            var i = (y * C + x) * 3
            var d = abs(Int(p[i]) - bg[0]) + abs(Int(p[i + 1]) - bg[1]) + abs(Int(p[i + 2]) - bg[2])
            if d >= thr:
                m[y * C + x] = 1
                cnt += 1
                sb += Int(p[i])
                sg += Int(p[i + 1])
                sr += Int(p[i + 2])
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
    if cnt < 64:
        return o^
    var bw = x1 - x0 + 1
    var bh = y1 - y0 + 1
    o[0] = 1.0
    o[1] = Float64(bw) / Float64(bh)
    o[2] = Float64(sr) / Float64(cnt)
    o[3] = Float64(sg) / Float64(cnt)
    o[4] = Float64(sb) / Float64(cnt)
    var lift = List[Float64](length=256, fill=0.0)
    for v in range(256):
        lift[v] = 255.0 * (Float64(v) / 255.0) ** 0.45
    var tot = List[Int](length=NG, fill=0)
    var on = List[Int](length=NG, fill=0)
    var sl = List[Float64](length=NG, fill=0.0)
    var all_l = 0.0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            var c = ((y - y0) * G // bh) * G + (x - x0) * G // bw
            tot[c] += 1
            if m[y * C + x] != 0:
                var i = (y * C + x) * 3
                var l = lift[(299 * Int(p[i + 2]) + 587 * Int(p[i + 1]) + 114 * Int(p[i])) // 1000]
                on[c] += 1
                sl[c] += l
                all_l += l
    var mean_l = max(all_l / Float64(cnt), 1.0)
    for c in range(NG):
        if tot[c] > 0:
            o[5 + c] = 255.0 * Float64(on[c]) / Float64(tot[c])
        if on[c] > 0:
            o[5 + NG + c] = min(255.0, 128.0 * (sl[c] / Float64(on[c])) / mean_l)
    return o^


def _hex(v: List[Float64], at: Int, n: Int) -> String:
    var s = String()
    for i in range(n):
        var b = Int(min(255.0, max(0.0, v[at + i])) + 0.5)
        s += String(HEX[byte=b // 16], HEX[byte=b % 16])
    return s^


def batch(mut a: Args) raises -> Bool:
    """viewSig OUT.tsv BATCH.tsv: BATCH.tsv rows `decoded path <TAB> original path <TAB> kind`. One row per picture: original path, aspect,
    r, g, b, coverage hex, shading hex; or the path and `empty` (no object) or `fail <reason>`."""
    var paths = List[String]()
    var origs = List[String]()
    for r in open(a.ins[0], "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) >= 2:
            paths.append(String(f[0]))
            origs.append(String(f[1]))
    var n = len(paths)
    var L = a.i("scale", 256)
    var thr = a.i("thr", 30)
    var res = List[List[Float64]]()
    var why = List[String]()
    for _ in range(n):
        res.append(List[Float64]())
        why.append(String())
    var rp = res.unsafe_ptr()
    var wp = why.unsafe_ptr()

    def task(i: Int) {imm}:  # each task writes only its own slot
        try:
            rp[i] = _sig(_load_any(paths[i]), L, thr)
        except e:
            wp[i] = String(e)

    par_dyn(task, n)
    var out = open(a.out, "w")
    for i in range(n):
        if why[i].byte_length() > 0:
            out.write(String(origs[i], "\tfail ", _esc(why[i]), "\n"))
        elif res[i][0] < 0.5:
            out.write(String(origs[i], "\tempty\n"))
        else:
            var v = res[i].copy()
            out.write(String(origs[i], "\t", round(v[1], 4), "\t", round(v[2], 1), "\t", round(v[3], 1), "\t", round(v[4], 1), "\t", _hex(v, 5, NG), "\t", _hex(v, 5 + NG, NG), "\n"))
    return True


def _unhex(s: String) -> List[UInt8]:
    var o = List[UInt8](length=NG, fill=0)
    var b = s.as_bytes()
    for i in range(NG):
        var h = Int(b[2 * i])
        var l = Int(b[2 * i + 1])
        o[i] = UInt8((h - 48 if h < 58 else h - 87) * 16 + (l - 48 if l < 58 else l - 87))
    return o^


def _sorted_dims(x: Float64, y: Float64, z: Float64) -> List[Float64]:
    """The three bbox dims, longest first, divided by the longest (0 0 0 when the box is empty)."""
    var d: List[Float64] = [x, y, z]
    for i in range(1, 3):
        var j = i
        while j > 0 and d[j - 1] < d[j]:
            var t = d[j]
            d[j] = d[j - 1]
            d[j - 1] = t
            j -= 1
    if d[0] <= 0.0:
        return [0.0, 0.0, 0.0]
    return [1.0, d[1] / d[0], d[2] / d[0]]


def _rel(a: Float64, b: Float64) -> Float64:
    var m = max(abs(a), abs(b))
    return 0.0 if m <= 0.0 else abs(a - b) / m


def pairs(mut a: Args) raises -> Bool:
    var ids = List[String]()
    var tris = List[Float64]()
    var verts = List[Float64]()
    var dims = List[List[Float64]]()
    var tex = List[Int]()
    var texpx = List[Int]()
    var asp = List[Float64]()
    var col = List[List[Float64]]()
    var occ = List[List[UInt8]]()
    var shd = List[List[UInt8]]()
    for r in open(a.ins[0], "r").read().split("\n"):
        var f = r.split("\t")
        if len(f) < 14:
            continue
        ids.append(String(f[0]))
        tris.append(atof(String(f[1])))
        verts.append(atof(String(f[2])))
        dims.append(_sorted_dims(atof(String(f[3])), atof(String(f[4])), atof(String(f[5]))))
        tex.append(atol(String(f[6])))
        texpx.append(atol(String(f[7])))
        if String(f[8]) == "-":
            asp.append(0.0)
            col.append(List[Float64]())
            occ.append(List[UInt8]())
            shd.append(List[UInt8]())
        else:
            asp.append(atof(String(f[8])))
            col.append([atof(String(f[9])), atof(String(f[10])), atof(String(f[11]))])
            occ.append(_unhex(String(f[12])))
            shd.append(_unhex(String(f[13])))
    var n = len(ids)
    var iou_min = a.f("iou", 0.985)
    var sh_max = a.f("shade", 8.0)
    var dim_tol = a.f("dim", 0.15)
    var asp_tol = a.f("asp", 0.15)
    var gtol = a.f("gtol", 0.02)
    var giou = a.f("giou", 0.6)
    var look_iou = a.f("lou", 0.85)
    var look_sh = a.f("lsh", 15.0)
    var look_dim = a.f("ldim", 0.05)
    var look_cd = a.f("lcd", 30.0)
    var out = open(a.out, "w")
    for i in range(n):
        var pi = len(occ[i]) > 0
        for j in range(i + 1, n):
            var pj = len(occ[j]) > 0
            var dd = max(abs(dims[i][1] - dims[j][1]), abs(dims[i][2] - dims[j][2]))
            var known = dims[i][0] > 0.0 and dims[j][0] > 0.0
            var geo = known and dd <= gtol and _rel(tris[i], tris[j]) <= gtol and _rel(verts[i], verts[j]) <= gtol and tex[i] == tex[j] and texpx[i] == texpx[j]
            var view_ok = pi and pj and known and dd <= dim_tol and _rel(asp[i], asp[j]) <= asp_tol
            if not (geo or view_ok):
                continue
            var iou = -1.0
            var sh = -1.0
            var cd = -1.0
            if pi and pj:
                var inter = 0
                var uni = 0
                var sd = 0
                var sn = 0
                for c in range(NG):
                    var u = Int(occ[i][c])
                    var v = Int(occ[j][c])
                    inter += min(u, v)
                    uni += max(u, v)
                    if u > 127 and v > 127:
                        sd += abs(Int(shd[i][c]) - Int(shd[j][c]))
                        sn += 1
                iou = Float64(inter) / Float64(max(uni, 1))
                sh = Float64(sd) / Float64(max(sn, 1))
                cd = ((col[i][0] - col[j][0]) ** 2 + (col[i][1] - col[j][1]) ** 2 + (col[i][2] - col[j][2]) ** 2) ** 0.5
            var rule = String()
            if view_ok and iou >= iou_min and sh <= sh_max:
                rule = String("view")
            if geo and (not (pi and pj) or iou >= giou):
                rule = String("geo") if rule.byte_length() == 0 else String("geo+view")
            if rule.byte_length() == 0 and pi and pj and known and iou >= look_iou and sh <= look_sh and dd <= look_dim and _rel(asp[i], asp[j]) <= look_dim and tex[i] == tex[j] and texpx[i] == texpx[j] and cd <= look_cd:
                rule = String("look")
            if rule.byte_length() == 0:
                continue
            out.write(String(ids[i], "\t", ids[j], "\t", rule, "\t", round(iou, 3), "\t", round(sh, 1), "\t", round(_rel(asp[i], asp[j]), 3), "\t", round(cd, 1), "\n"))
    return True


def run(mut a: Args) raises -> Bool:
    if a.op == "viewSig":
        return batch(a)
    if a.op == "sigPairs":
        return pairs(a)
    return False
