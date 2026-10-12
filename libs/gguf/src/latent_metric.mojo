"""latent-metric REF.gguf TEST.gguf PROMPTS.txt OUT.json: does TEST keep the geometry latent steps read?

One row per prompt (its last position). Forward passes come from hidden-probe-dump (llama.cpp CPU: result_norm and
result_output per prompt); everything after the dump is ours and deterministic. Keys (all numbers):
  prompts                  prompt count
  cos_mean, cos_min        cosine of the final-norm hiddens, REF vs TEST
  top1_agree               share of prompts whose logit argmax is equal
  soft_cos_mean, _min      cosine of softmax(logits) . token_embd, each model with its own dequantized token_embd
  wa_recovery              TEST's W_a known-answer probe: of 256 tokens t = (k*977+13) % vocab, the share whose
                           W_out[t] W_a has nearest token_embd row t by cosine, with
                           W_a = (W_out^T W_out + lambda I)^-1 W_out^T W_in, lambda = 1e-4 trace(W_out^T W_out)/d.
Token matrices are streamed in row chunks of CHUNK rows through the U6 dequantizer, never held whole.
"""
from std.sys import argv, exit
from std.ffi import external_call
from std.os import getenv
from std.math import exp, sqrt
from std.utils import StaticTuple
from max.algorithm import parallelize
from gguf.model import Gguf, open_fd, pread_into
from gguf.dequant import quant_block, deq_rows

comptime F32P = Pointer[Float32, MutUntrackedOrigin]
comptime F64P = Pointer[Float64, MutUntrackedOrigin]
comptime U8P = Pointer[UInt8, MutUntrackedOrigin]
comptime CHUNK = 2048  # token rows per dequant round trip (multiple of 16: SIMD reduction length of the Gram)
comptime GROUP = 64  # prompts whose softmax rows are held at once
comptime PROBES = 256
comptime TB = 4  # Gram tile edge: TB x TB SIMD accumulators of 16 f32

def f32p(mut l: List[Float32]) -> F32P:
    return F32P(unsafe_from_address=Int(l.unsafe_ptr()))

def f64p(mut l: List[Float64]) -> F64P:
    return F64P(unsafe_from_address=Int(l.unsafe_ptr()))

def u8p(mut l: List[UInt8]) -> U8P:
    return U8P(unsafe_from_address=Int(l.unsafe_ptr()))

def sh(s: String) -> String:
    return "'" + String(s.replace("'", "'\\''")) + "'"

def system(cmd: String) -> Int:
    var c = cmd.copy()
    return Int(external_call["system", Int32](c.as_c_string_span().ptr()))

struct Mat(Copyable, Movable):
    """A 2-D tensor on disk: n rows of d elements of ggml type ty, row r at file offset at + r * rb."""
    var fd: Int32
    var at: Int
    var ty: Int
    var d: Int
    var n: Int
    var rb: Int

    def __init__(out self, g: Gguf, name: String) raises:
        for k in range(len(g.tensors)):
            if g.tensors[k].name == name:
                var info = quant_block(g.tensors[k].ttype)
                if info[0] == 0 or len(g.tensors[k].dims) != 2:
                    raise Error(name + ": need a 2-D tensor of a dequantizable type, got type " + String(g.tensors[k].ttype))
                self.fd = g.fd
                self.at = g.data_offset + g.tensors[k].offset
                self.ty = g.tensors[k].ttype
                self.d = g.tensors[k].dims[0]
                self.n = g.tensors[k].dims[1]
                self.rb = self.d // info[0] * info[1]
                return
        raise Error("no tensor " + name)

    def rows(self, r0: Int, nr: Int, mut raw: List[UInt8], dst: F32P) raises:
        """Dequantize rows [r0, r0 + nr) into dst (nr * d f32); raw is the byte staging buffer, grown as needed."""
        if len(raw) < nr * self.rb:
            raw = List[UInt8](length=nr * self.rb, fill=0)
        pread_into(self.fd, raw, 0, nr * self.rb, self.at + r0 * self.rb)
        deq_rows(self.ty, u8p(raw), self.d, nr, dst)

@always_inline
def dot32(a: F32P, b: F32P, n: Int) -> Float32:
    var acc = SIMD[DType.float32, 16](0)
    var i = 0
    while i + 16 <= n:
        acc = a.unsafe_load[width=16](i).fma(b.unsafe_load[width=16](i), acc)
        i += 16
    var s = acc.reduce_add()
    while i < n:
        s += a[unsafe_offset=i] * b[unsafe_offset=i]
        i += 1
    return s

@always_inline
def dot64(a: F64P, b: F64P, n: Int) -> Float64:
    var acc = SIMD[DType.float64, 8](0)
    var i = 0
    while i + 8 <= n:
        acc = a.unsafe_load[width=8](i).fma(b.unsafe_load[width=8](i), acc)
        i += 8
    var s = acc.reduce_add()
    while i < n:
        s += a[unsafe_offset=i] * b[unsafe_offset=i]
        i += 1
    return s

def cosine(a: F64P, b: F64P, n: Int) -> Float64:
    """dot / sqrt(|a|^2 |b|^2): exactly 1.0 for identical vectors (sqrt(x*x) == x)."""
    return dot64(a, b, n) / sqrt(dot64(a, a, n) * dot64(b, b, n))

# ---- dumps -------------------------------------------------------------------------------------------------------

struct Dump(Movable):
    """result_norm and result_output rows of one hidden-probe-dump directory, read on demand from data.bin."""
    var fd: Int32
    var nat: List[Int]
    var oat: List[Int]
    var d: Int
    var vocab: Int

    def __init__(out self, dir: String) raises:
        self.nat = List[Int]()
        self.oat = List[Int]()
        self.d = 0
        self.vocab = 0
        with open(dir + "/index.txt", "r") as f:
            for line in f.read().split("\n"):
                var p = line.split(" ")
                if len(p) != 4 or (String(p[0]) != "result_norm" and String(p[0]) != "result_output"):
                    continue
                if String(p[0]) == "result_norm":
                    self.nat.append(Int(p[2]))
                    self.d = Int(p[3])
                else:
                    self.oat.append(Int(p[2]))
                    self.vocab = Int(p[3])
        self.fd = open_fd(dir + "/data.bin", 0)

    def __deinit__(deinit self):
        _ = external_call["close", Int32](self.fd)

    def row(self, at: Int, n: Int, mut buf: List[UInt8]) raises -> F32P:
        if len(buf) < 4 * n:
            buf = List[UInt8](length=4 * n, fill=0)
        pread_into(self.fd, buf, 0, 4 * n, at)
        return F32P(unsafe_from_address=Int(buf.unsafe_ptr()))

def argmax(p: F32P, n: Int) -> Int:
    var best = 0
    for i in range(1, n):
        if p[unsafe_offset=i] > p[unsafe_offset=best]:
            best = i
    return best

def softmax_into(logits: F32P, n: Int, dst: F32P):
    var m = Float64(logits[unsafe_offset=argmax(logits, n)])
    var s = 0.0
    for i in range(n):
        s += exp(Float64(logits[unsafe_offset=i]) - m)
    for i in range(n):
        dst[unsafe_offset=i] = Float32(exp(Float64(logits[unsafe_offset=i]) - m) / s)

# ---- passes over a token matrix ----------------------------------------------------------------------------------

def soft_vectors(m: Mat, dump: Dump, p0: Int, np: Int, mut s: List[Float64]) raises:
    """s[(p0+i)*d + j] = sum_v softmax(logits_i)[v] * m[v][j] for prompts p0..p0+np, one streamed pass over m."""
    var d = m.d
    var probs = List[Float32](length=np * m.n, fill=0.0)
    var buf = List[UInt8](length=4 * m.n, fill=0)
    for i in range(np):
        softmax_into(dump.row(dump.oat[p0 + i], m.n, buf), m.n, f32p(probs).unsafe_offset(i * m.n))
    var rows = List[Float32](length=CHUNK * d, fill=0.0)
    var raw = List[UInt8]()
    var rp = f32p(rows)
    var pp = f32p(probs)
    var sp = f64p(s)
    var n = m.n
    var r0 = 0
    while r0 < n:
        var nr = min(CHUNK, n - r0)
        m.rows(r0, nr, raw, rp)

        def work(i: Int) {var rp, var pp, var sp, var d, var n, var r0, var nr, var p0}:
            var acc = sp.unsafe_offset((p0 + i) * d)
            for v in range(nr):
                var w = Float64(pp[unsafe_offset=i * n + r0 + v])
                var e = rp.unsafe_offset(v * d)
                var j = 0
                while j + 8 <= d:
                    var x = e.unsafe_load[width=8](j).cast[DType.float64]()
                    acc.unsafe_store(j, x.fma(SIMD[DType.float64, 8](w), acc.unsafe_load[width=8](j)))
                    j += 8
                while j < d:
                    acc[unsafe_offset=j] += w * Float64(e[unsafe_offset=j])
                    j += 1

        parallelize(work, np)
        r0 += nr
    _ = len(rows) + len(probs) + len(buf)

def nearest_rows(m: Mat, q: F32P, nq: Int, mut best: List[Int]) raises:
    """best[k] = row of m with the largest cosine to q[k] (first on ties); nq is a multiple of 4."""
    var d = m.d
    var n = m.n
    var rows = List[Float32](length=CHUNK * d, fill=0.0)
    var inv = List[Float32](length=CHUNK, fill=0.0)
    var raw = List[UInt8]()
    var bs = List[Float32](length=nq, fill=-3.0e38)
    var rp = f32p(rows)
    var ip = f32p(inv)
    var bp = f32p(bs)
    var r0 = 0
    var bi = List[Int](length=nq, fill=0)
    var bip = bi.unsafe_ptr()
    while r0 < n:
        var nr = min(CHUNK, n - r0)
        m.rows(r0, nr, raw, rp)

        def norms(v: Int) {var rp, var ip, var d}:
            var e = rp.unsafe_offset(v * d)
            var s = sqrt(dot32(e, e, d))
            ip[unsafe_offset=v] = 1.0 / s if s > 0.0 else 0.0

        parallelize(norms, nr)

        def work(g: Int) {var rp, var ip, var bp, var bip, var q, var d, var nr, var r0}:
            var d16 = d // 16 * 16
            for v in range(nr):
                var e = rp.unsafe_offset(v * d)
                var acc = StaticTuple[SIMD[DType.float32, 16], 4](fill=SIMD[DType.float32, 16](0))
                var j = 0
                while j < d16:
                    var x = e.unsafe_load[width=16](j)
                    comptime for a in range(4):
                        acc[a] = x.fma(q.unsafe_load[width=16]((4 * g + a) * d + j), acc[a])
                    j += 16
                comptime for a in range(4):
                    var s = acc[a].reduce_add()
                    for t in range(d16, d):
                        s += e[unsafe_offset=t] * q[unsafe_offset=(4 * g + a) * d + t]
                    s *= ip[unsafe_offset=v]
                    if s > bp[unsafe_offset=4 * g + a]:
                        bp[unsafe_offset=4 * g + a] = s
                        bip[unsafe_offset=4 * g + a] = r0 + v

        parallelize(work, nq // 4)
        r0 += nr
    best = bi^
    _ = len(rows) + len(inv) + len(bs)

# ---- W_a known-answer probe --------------------------------------------------------------------------------------

def tile4(a: F32P, b: F32P, i0: Int, j0: Int, dst: F64P, ld: Int):
    """dst[i0..i0+4, j0..j0+4] += a[i0+.., :] . b[j0+.., :] over one CHUNK of columns (a, b are d x CHUNK)."""
    var acc = StaticTuple[SIMD[DType.float32, 16], TB * TB](fill=SIMD[DType.float32, 16](0))
    var r = 0
    while r < CHUNK:
        comptime for x in range(TB):
            var u = a.unsafe_load[width=16]((i0 + x) * CHUNK + r)
            comptime for y in range(TB):
                acc[x * TB + y] = u.fma(b.unsafe_load[width=16]((j0 + y) * CHUNK + r), acc[x * TB + y])
        r += 16
    comptime for x in range(TB):
        comptime for y in range(TB):
            dst[unsafe_offset=(i0 + x) * ld + j0 + y] += Float64(acc[x * TB + y].reduce_add())

def gram(a_m: Mat, b_m: Mat, tied: Bool, ld: Int, mut G: List[Float64], mut M: List[Float64]) raises:
    """G = A^T A and (untied) M = A^T B for token matrices A = output, B = token_embd; ld = d rounded up to TB."""
    var d = a_m.d
    var rows = List[Float32](length=CHUNK * d, fill=0.0)
    var raw = List[UInt8]()
    var at = List[Float32](length=ld * CHUNK, fill=0.0)  # columns of A: at[i * CHUNK + r] = A[r0 + r][i]
    var bt = List[Float32](length=0 if tied else ld * CHUNK, fill=0.0)
    var rp = f32p(rows)
    var ap = f32p(at)
    var bp = f32p(bt)
    var gp = f64p(G)
    var mp = f64p(M)
    var r0 = 0
    while r0 < a_m.n:
        var nr = min(CHUNK, a_m.n - r0)
        a_m.rows(r0, nr, raw, rp)

        def tr_a(i: Int) {var rp, var ap, var d, var nr}:
            for r in range(nr):
                ap[unsafe_offset=i * CHUNK + r] = rp[unsafe_offset=r * d + i]
            for r in range(nr, CHUNK):
                ap[unsafe_offset=i * CHUNK + r] = 0.0

        parallelize(tr_a, d)
        if not tied:
            b_m.rows(r0, nr, raw, rp)

            def tr_b(i: Int) {var rp, var bp, var d, var nr}:
                for r in range(nr):
                    bp[unsafe_offset=i * CHUNK + r] = rp[unsafe_offset=r * d + i]
                for r in range(nr, CHUNK):
                    bp[unsafe_offset=i * CHUNK + r] = 0.0

            parallelize(tr_b, d)

        def gtile(ib: Int) {var ap, var gp, var ld}:
            var j0 = ib * TB
            while j0 < ld:
                tile4(ap, ap, ib * TB, j0, gp, ld)
                j0 += TB

        parallelize(gtile, ld // TB)
        if not tied:

            def mtile(ib: Int) {var ap, var bp, var mp, var ld}:
                var j0 = 0
                while j0 < ld:
                    tile4(ap, bp, ib * TB, j0, mp, ld)
                    j0 += TB

            parallelize(mtile, ld // TB)
        r0 += nr
    for i in range(ld):  # tiles cover the upper triangle of G
        for j in range(i):
            gp[unsafe_offset=i * ld + j] = gp[unsafe_offset=j * ld + i]
    _ = len(rows) + len(at) + len(bt)

def wa_recovery(g: Gguf) raises -> Float64:
    var t_in = Mat(g, "token_embd.weight")
    var tied = True
    for k in range(len(g.tensors)):
        if g.tensors[k].name == "output.weight":
            tied = False
    var t_out = t_in.copy() if tied else Mat(g, "output.weight")
    var d = t_in.d
    if t_out.d != d or t_out.n != t_in.n:
        raise Error("output.weight and token_embd.weight shapes differ")
    var ld = (d + TB - 1) // TB * TB
    var G = List[Float64](length=ld * ld, fill=0.0)
    var M = List[Float64](length=0 if tied else ld * ld, fill=0.0)
    gram(t_out, t_in, tied, ld, G, M)
    var gp = f64p(G)
    var bmat = gp if tied else f64p(M)
    var tr = 0.0
    for i in range(d):
        tr += gp[unsafe_offset=i * ld + i]
    var lam = 1e-4 * tr / Float64(d)
    var Lm = List[Float64](length=ld * ld, fill=0.0)  # lower Cholesky factor of G + lambda I, row-major
    var lp = f64p(Lm)
    for i in range(d):
        for j in range(i + 1):
            lp[unsafe_offset=i * ld + j] = gp[unsafe_offset=i * ld + j]
        lp[unsafe_offset=i * ld + i] += lam
    for j in range(d):
        var s = lp[unsafe_offset=j * ld + j] - dot64(lp.unsafe_offset(j * ld), lp.unsafe_offset(j * ld), j)
        if s <= 0.0:
            raise Error("W_out^T W_out + lambda I is not positive definite at " + String(j))
        var djj = sqrt(s)
        lp[unsafe_offset=j * ld + j] = djj
        for i in range(j + 1, d):
            lp[unsafe_offset=i * ld + j] = (lp[unsafe_offset=i * ld + j] - dot64(lp.unsafe_offset(i * ld), lp.unsafe_offset(j * ld), j)) / djj

    # query k: h = W_out[t_k]; z = (G + lambda I)^-1 h (L y = h, L^T z = y); e = z^T B; both are cheap next to the Gram
    var q = List[Float32](length=PROBES * d, fill=0.0)
    var toks = List[Int]()
    var raw = List[UInt8]()
    var hs = List[Float32](length=PROBES * d, fill=0.0)
    for k in range(PROBES):
        var t = (k * 977 + 13) % t_in.n
        toks.append(t)
        t_out.rows(t, 1, raw, f32p(hs).unsafe_offset(k * d))
    var hp = f32p(hs)
    var qp = f32p(q)

    def solve(k: Int) {var hp, var lp, var bmat, var qp, var d, var ld}:
        var y = List[Float64](length=d, fill=0.0)
        var e = List[Float64](length=d, fill=0.0)
        var yp = f64p(y)
        var ep = f64p(e)
        for i in range(d):
            yp[unsafe_offset=i] = (Float64(hp[unsafe_offset=k * d + i]) - dot64(lp.unsafe_offset(i * ld), yp, i)) / lp[unsafe_offset=i * ld + i]
        var i = d - 1
        while i >= 0:
            var zi = yp[unsafe_offset=i] / lp[unsafe_offset=i * ld + i]
            yp[unsafe_offset=i] = zi
            for c in range(i):
                yp[unsafe_offset=c] -= lp[unsafe_offset=i * ld + c] * zi
            i -= 1
        for i in range(d):
            var zi = yp[unsafe_offset=i]
            for c in range(d):
                ep[unsafe_offset=c] += zi * bmat[unsafe_offset=i * ld + c]
        for c in range(d):
            qp[unsafe_offset=k * d + c] = Float32(ep[unsafe_offset=c])
        _ = len(y) + len(e)

    parallelize(solve, PROBES)
    var best = List[Int]()
    nearest_rows(t_in, qp, PROBES, best)
    var hit = 0
    for k in range(PROBES):
        if best[k] == toks[k]:
            hit += 1
    _ = len(hs) + len(q) + len(G) + len(M) + len(Lm)
    return Float64(hit) / Float64(PROBES)

# ---- driver ------------------------------------------------------------------------------------------------------

def num(x: Float64) raises -> String:
    if not (x - x == 0.0):
        raise Error("non-finite metric " + String(x))
    return String(x)

def run_dump(model: String, prompts: String, dir: String) raises:
    if getenv("LATENT_METRIC_REUSE", "") != "" and system("test -f " + sh(dir + "/index.txt")) == 0:
        return  # development: LATENT_METRIC_REUSE keeps dumps after the run and reuses the ones already there
    var tool = getenv("HIDDEN_PROBE_DUMP", getenv("HOME", "") + "/iTools/bin/hidden-probe-dump")
    _ = system("rm -rf " + sh(dir))
    if system(sh(tool) + " " + sh(model) + " " + sh(prompts) + " " + sh(dir) + " > " + sh(dir + ".log") + " 2>&1") != 0:
        raise Error("hidden-probe-dump failed on " + model + ", log " + dir + ".log")
    _ = system("rm -f " + sh(dir + ".log"))

def score(refm: String, test: String, prompts: String, dest: String, rd: String, td: String) raises:
    var n = 0
    with open(prompts, "r") as f:
        for line in f.read().split("\n"):
            if line.byte_length() > 0:
                n += 1
    if n == 0:
        raise Error("no prompts in " + prompts)
    var same = refm == test
    run_dump(refm, prompts, rd)
    if not same:
        run_dump(test, prompts, td)
    var dr = Dump(rd)
    var dt = Dump(rd if same else td)
    if len(dr.nat) != n or len(dr.oat) != n or len(dt.nat) != n or len(dt.oat) != n:
        raise Error("dumps hold " + String(len(dr.nat)) + "/" + String(len(dt.nat)) + " result_norm rows for " + String(n) + " prompts")
    if dr.d != dt.d or dr.vocab != dt.vocab:
        raise Error("REF and TEST disagree on hidden width or vocabulary")
    var d = dr.d
    var gr = Gguf(refm)
    var gt = Gguf(test)
    var mr = Mat(gr, "token_embd.weight")
    var mt = Mat(gt, "token_embd.weight")
    if mr.d != d or mt.d != d or mr.n != dr.vocab or mt.n != dr.vocab:
        raise Error("token_embd shape does not match the dumped hidden/logits")

    var cmean = 0.0
    var cmin = 2.0
    var agree = 0
    var ba = List[UInt8]()
    var bb = List[UInt8]()
    var ha = List[Float64](length=d, fill=0.0)
    var hb = List[Float64](length=d, fill=0.0)
    var la = List[Int]()
    for p in range(n):
        var a = dr.row(dr.nat[p], d, ba)
        var b = dt.row(dt.nat[p], d, bb)
        for i in range(d):
            ha[i] = Float64(a[unsafe_offset=i])
            hb[i] = Float64(b[unsafe_offset=i])
        var c = cosine(f64p(ha), f64p(hb), d)
        cmean += c
        cmin = min(cmin, c)
        var x = argmax(dr.row(dr.oat[p], dr.vocab, ba), dr.vocab)
        la.append(x)
        if argmax(dt.row(dt.oat[p], dr.vocab, bb), dr.vocab) == x:
            agree += 1

    var smean = 0.0
    var smin = 2.0
    var p0 = 0
    while p0 < n:
        var np = min(GROUP, n - p0)
        var sr = List[Float64](length=n * d, fill=0.0)
        var st = List[Float64](length=n * d, fill=0.0)
        soft_vectors(mr, dr, p0, np, sr)
        soft_vectors(mt, dt, p0, np, st)
        for p in range(p0, p0 + np):
            var c = cosine(f64p(sr).unsafe_offset(p * d), f64p(st).unsafe_offset(p * d), d)
            smean += c
            smin = min(smin, c)
        p0 += np
    var wa = wa_recovery(gt)
    _ = gr.fd  # Mat holds only the fd: keep the reader open until the last pass

    var j = String("{")
    j += '"prompts": ' + String(n)
    j += ', "cos_mean": ' + num(cmean / Float64(n))
    j += ', "cos_min": ' + num(cmin)
    j += ', "top1_agree": ' + num(Float64(agree) / Float64(n))
    j += ', "soft_cos_mean": ' + num(smean / Float64(n))
    j += ', "soft_cos_min": ' + num(smin)
    j += ', "wa_recovery": ' + num(wa)
    j += "}\n"
    with open(dest, "w") as f:
        f.write(j)

def run() raises:
    var a = argv()
    if len(a) != 5:
        raise Error("usage: latent-metric REF.gguf TEST.gguf PROMPTS.txt OUT.json")
    var dest = String(a[4])
    var rd = dest + ".dump-ref"
    var td = dest + ".dump-test"
    try:
        score(String(a[1]), String(a[2]), String(a[3]), dest, rd, td)
    except e:
        if getenv("LATENT_METRIC_REUSE", "") == "":
            _ = system("rm -rf " + sh(rd) + " " + sh(td))
        raise e^
    if getenv("LATENT_METRIC_REUSE", "") == "":
        _ = system("rm -rf " + sh(rd) + " " + sh(td))

def main():
    try:
        run()
    except e:
        print("FAIL latent-metric:", e)
        exit(1)
