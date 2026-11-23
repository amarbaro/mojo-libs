# embindex: flat embedding index (plan R8a rank, R8b persistence and dedupe). Brute force cosine over float32 rows (SigLIP 768,
# ArcFace 512, any width), arithmetic in float64. Re-identification and few-shot calibration (R8c) are not built.
#   embTopK OUT DB Q k= norm=   per query row the k best database rows: OUT int32 M x k (row numbers), OUT.1 float32 M x k (cosine).
#                               Order: cosine rounded to 1e-9 descending, then the lower row number first, so exact duplicates
#                               rank by position and a rounding difference of 1e-16 cannot reorder them. k > N pads with -1 and -2.
#                               norm=0: DB rows are already unit length (a file written by embNorm), skip normalizing them.
#                               A zero row has cosine 0 with everything.
#   embNorm OUT DB              the persisted index: unit-length rows (zero rows stay zero), float32. Saved by `save`, i.e. the
#                               .mcv file is the index; embTopK on it with norm=0 ranks as embTopK on the raw rows.
#   embDup OUT DB thr=          leader clustering in row order: OUT int32 N x 1 = the first earlier leader with cosine >= thr, else
#                               the row itself. Not transitive: a chain of near rows stays split at the leader.
# No speed claim: the 4,202 x 768 timing row belongs to the boss's timing run.
from std.math import sqrt
from mojocv.mat import Mat, load, save
from mojocv.core import Args

comptime F32 = DType.float32
comptime I32 = DType.int32


def _unit_rows(m: Mat[F32], unit: Bool) raises -> List[Float64]:
    if m.ch != 1:
        raise Error("mojocv: emb ops need one-channel N x D matrices")
    var d = m.cols
    var u = List[Float64](length=m.rows * d, fill=0.0)
    for i in range(m.rows):
        var s = Float64(0)
        for j in range(d):
            var v = Float64(m.data[i * d + j])
            if v != v or v > 3.0e38 or v < -3.0e38:
                raise Error("mojocv: emb: row " + String(i) + " holds a NaN or an infinity")
            u[i * d + j] = v
            s += v * v
        if not unit and s > 0.0:
            for j in range(d):
                u[i * d + j] /= sqrt(s)
    return u^


def emb_norm(db: Mat[F32]) raises -> Mat[F32]:
    var u = _unit_rows(db, False)
    var o = Mat[F32](db.rows, db.cols, 1, False)
    for i in range(len(u)):
        o.data[i] = Float32(u[i])
    return o^


def emb_topk(db: Mat[F32], q: Mat[F32], k: Int, unit_db: Bool, mut oi: Mat[I32], mut os: Mat[F32]) raises:
    if db.cols != q.cols:
        raise Error("mojocv: embTopK: width " + String(q.cols) + " of the queries is not " + String(db.cols) + " of the index")
    if k < 1:
        raise Error("mojocv: embTopK: k must be >= 1")
    var d = db.cols
    var ud = _unit_rows(db, unit_db)
    var uq = _unit_rows(q, False)
    var bk = List[Int](length=k, fill=0)
    var bi = List[Int](length=k, fill=-1)
    var bs = List[Float64](length=k, fill=-2.0)
    for m in range(q.rows):
        var have = 0
        for j in range(db.rows):
            var s = Float64(0)
            for t in range(d):
                s += uq[m * d + t] * ud[j * d + t]
            var key = Int(round(s * 1.0e9))
            var pos = have  # after every entry with a key >= this one: an earlier row wins a tie
            while pos > 0 and bk[pos - 1] < key:
                pos -= 1
            if pos >= k:
                continue
            var p = have if have < k else k - 1
            while p > pos:
                bk[p] = bk[p - 1]
                bi[p] = bi[p - 1]
                bs[p] = bs[p - 1]
                p -= 1
            bk[pos] = key
            bi[pos] = j
            bs[pos] = s
            if have < k:
                have += 1
        for t in range(k):
            oi.data[m * k + t] = Int32(bi[t]) if t < have else Int32(-1)
            os.data[m * k + t] = Float32(bs[t]) if t < have else Float32(-2.0)


def emb_dup(db: Mat[F32], thr: Float64) raises -> Mat[I32]:
    var d = db.cols
    var u = _unit_rows(db, False)
    var rep = Mat[I32](db.rows, 1, 1, False)
    for i in range(db.rows):
        rep.data[i] = Int32(i)
        for j in range(i):
            if Int(rep.data[j]) != j:
                continue
            var s = Float64(0)
            for t in range(d):
                s += u[i * d + t] * u[j * d + t]
            if s >= thr:
                rep.data[i] = Int32(j)
                break
    return rep^


def run(mut a: Args) raises -> Bool:
    if a.op == "embTopK":
        if len(a.ins) < 2:
            raise Error("mojocv: embTopK needs 2 input file(s)")
        var db = load[F32](a.ins[0])
        var q = load[F32](a.ins[1])
        var k = max(a.i("k", 5), 1)
        var oi = Mat[I32](q.rows, k, 1, False)
        var os = Mat[F32](q.rows, k, 1, False)
        while a.again():
            emb_topk(db, q, k, a.i("norm", 1) == 0, oi, os)
        save(oi, a.out)
        save(os, a.out + ".1")
    elif a.op == "embNorm":
        if len(a.ins) < 1:
            raise Error("mojocv: embNorm needs 1 input file(s)")
        var db = load[F32](a.ins[0])
        var o = Mat[F32](0, 0)
        while a.again():
            o = emb_norm(db)
        save(o, a.out)
    elif a.op == "embDup":
        if len(a.ins) < 1:
            raise Error("mojocv: embDup needs 1 input file(s)")
        var db = load[F32](a.ins[0])
        var o = Mat[I32](0, 0)
        while a.again():
            o = emb_dup(db, a.f("thr", 0.95))
        save(o, a.out)
    else:
        return False
    return True
