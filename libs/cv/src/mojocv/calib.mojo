# calib: calibration of a scorer's confidences (plan R9). Dirichlet-multinomial loss on vote counts (2609.17130), the
# concentration fit that loss gives, temperature scaling of logits, the expected calibration error, and abstention by a
# confidence threshold. Float64 inputs and outputs; labels are int32 class indices. No speed claim.
#   calDm      counts alpha        per-row Dirichlet-multinomial negative log-likelihood (N x 1)
#   calFitDm   counts p            alpha = s * p, s from a golden-section search on log s: [log s, mean NLL at s, mean NLL at s = 1]
#   calTemp    logits labels       T from a golden-section search on log T: [T, mean NLL at T, mean NLL at T = 1]
#   calEval    logits labels T=    [ECE, mean NLL, accuracy, 1 if over-confident: ECE > max_ece and mean confidence > accuracy];
#                                  T from a third input (1 x 1) when given, else T=, else 1
#   calAbstain logits labels T=    largest coverage with accepted error <= max_err: [threshold, coverage, error]; a third
#                                  input (1 x 1 threshold) skips the search and reports coverage and error at that threshold
from std.math import exp, log, lgamma
from std.builtin.sort import sort
from mojocv.mat import Mat, load, save
from mojocv.core import Args

comptime F64 = DType.float64
comptime I32 = DType.int32
comptime PHI = 0.6180339887498949


def dm_nll(counts: Mat[F64], alpha: Mat[F64]) raises -> Mat[F64]:
    """-log P(counts | alpha) per row: lgamma(n+1) - sum lgamma(c+1) + lgamma(A) - lgamma(n+A) + sum (lgamma(c+a) - lgamma(a))."""
    if not counts.same_shape(alpha) or counts.ch != 1:
        raise Error("mojocv: calDm: counts and alpha must be N x K, one channel, one shape")
    var k = counts.cols
    var o = Mat[F64](counts.rows, 1, 1, False)
    for i in range(counts.rows):
        var n = Float64(0)
        var a = Float64(0)
        var s = Float64(0)
        for j in range(k):
            var c = counts.data[i * k + j]
            var al = alpha.data[i * k + j]
            if c < 0 or al <= 0:
                raise Error("mojocv: calDm: counts must be >= 0 and alpha > 0")
            n += c
            a += al
            s += lgamma(c + al) - lgamma(al) - lgamma(c + 1.0)
        o.data[i] = -(lgamma(n + 1.0) + lgamma(a) - lgamma(n + a) + s)
    return o^


def _dm_mean(counts: Mat[F64], p: Mat[F64], s: Float64) raises -> Float64:
    var a = Mat[F64](p.rows, p.cols, 1, False)
    for i in range(p.size()):
        a.data[i] = s * max(p.data[i], 1e-6)
    var r = dm_nll(counts, a)
    var t = Float64(0)
    for i in range(r.rows):
        t += r.data[i]
    return t / Float64(r.rows)


def fit_dm(counts: Mat[F64], p: Mat[F64]) raises -> Mat[F64]:
    """Concentration s of alpha = s * max(p, 1e-6) minimising the mean NLL, search range s in [0.01, 10000]."""
    var a = log(0.01)
    var b = log(10000.0)
    var c = b - PHI * (b - a)
    var d = a + PHI * (b - a)
    var fc = _dm_mean(counts, p, exp(c))
    var fd = _dm_mean(counts, p, exp(d))
    for _ in range(120):
        if fc < fd:
            b = d
            d = c
            fd = fc
            c = b - PHI * (b - a)
            fc = _dm_mean(counts, p, exp(c))
        else:
            a = c
            c = d
            fc = fd
            d = a + PHI * (b - a)
            fd = _dm_mean(counts, p, exp(d))
    var x = 0.5 * (a + b)
    var o = Mat[F64](1, 3, 1, False)
    o.data[0] = x
    o.data[1] = _dm_mean(counts, p, exp(x))
    o.data[2] = _dm_mean(counts, p, 1.0)
    return o^


def _check_logits(z: Mat[F64], y: Mat[I32], op: String) raises:
    if z.ch != 1 or y.cols != 1 or y.rows != z.rows or z.cols < 2:
        raise Error("mojocv: " + op + ": logits must be N x K (K >= 2), labels N x 1")
    for i in range(y.rows):
        if y.data[i] < 0 or Int(y.data[i]) >= z.cols:
            raise Error("mojocv: " + op + ": label out of range")


def _softmax_row(z: Mat[F64], i: Int, t: Float64, mut p: List[Float64]):
    """softmax(z[i] / t) into p."""
    var k = z.cols
    var m = z.data[i * k]
    for j in range(1, k):
        m = max(m, z.data[i * k + j])
    var s = Float64(0)
    for j in range(k):
        p[j] = exp((z.data[i * k + j] - m) / t)
        s += p[j]
    for j in range(k):
        p[j] /= s


def _nll_t(z: Mat[F64], y: Mat[I32], t: Float64) -> Float64:
    var k = z.cols
    var p = List[Float64](length=k, fill=0)
    var tot = Float64(0)
    for i in range(z.rows):
        _softmax_row(z, i, t, p)
        tot -= log(max(p[Int(y.data[i])], 1e-300))
    return tot / Float64(z.rows)


def fit_temperature(z: Mat[F64], y: Mat[I32]) raises -> Mat[F64]:
    """Temperature T in [0.05, 20] minimising the mean NLL of softmax(z / T)."""
    _check_logits(z, y, "calTemp")
    var a = log(0.05)
    var b = log(20.0)
    var c = b - PHI * (b - a)
    var d = a + PHI * (b - a)
    var fc = _nll_t(z, y, exp(c))
    var fd = _nll_t(z, y, exp(d))
    for _ in range(120):
        if fc < fd:
            b = d
            d = c
            fd = fc
            c = b - PHI * (b - a)
            fc = _nll_t(z, y, exp(c))
        else:
            a = c
            c = d
            fc = fd
            d = a + PHI * (b - a)
            fd = _nll_t(z, y, exp(d))
    var t = exp(0.5 * (a + b))
    var o = Mat[F64](1, 3, 1, False)
    o.data[0] = t
    o.data[1] = _nll_t(z, y, t)
    o.data[2] = _nll_t(z, y, 1.0)
    return o^


def conf_correct(z: Mat[F64], y: Mat[I32], t: Float64) -> Mat[F64]:
    """N x 2: max softmax(z / t) and 1 when its first argmax is the label."""
    var k = z.cols
    var p = List[Float64](length=k, fill=0)
    var o = Mat[F64](z.rows, 2, 1, False)
    for i in range(z.rows):
        _softmax_row(z, i, t, p)
        var best = 0
        for j in range(1, k):
            if p[j] > p[best]:
                best = j
        o.data[2 * i] = p[best]
        o.data[2 * i + 1] = 1.0 if best == Int(y.data[i]) else 0.0
    return o^


def ece_report(z: Mat[F64], y: Mat[I32], t: Float64, bins: Int, max_ece: Float64) raises -> Mat[F64]:
    """[ECE over `bins` equal-width bins (lo, hi], mean NLL, accuracy, over-confident flag]."""
    _check_logits(z, y, "calEval")
    var cc = conf_correct(z, y, t)
    var n = z.rows
    var bn = List[Float64](length=bins, fill=0)
    var bc = List[Float64](length=bins, fill=0)
    var ba = List[Float64](length=bins, fill=0)
    var acc = Float64(0)
    var mean_conf = Float64(0)
    for i in range(n):
        var c = cc.data[2 * i]
        var b = min(max(Int(-((-c * Float64(bins)) // 1.0)) - 1, 0), bins - 1)  # ceil(c * bins) - 1
        bn[b] += 1
        bc[b] += c
        ba[b] += cc.data[2 * i + 1]
        acc += cc.data[2 * i + 1]
        mean_conf += c
    acc /= Float64(n)
    mean_conf /= Float64(n)
    var e = Float64(0)
    for b in range(bins):
        if bn[b] > 0:
            e += bn[b] / Float64(n) * abs(ba[b] / bn[b] - bc[b] / bn[b])
    var o = Mat[F64](1, 4, 1, False)
    o.data[0] = e
    o.data[1] = _nll_t(z, y, t)
    o.data[2] = acc
    o.data[3] = 1.0 if (e > max_ece and mean_conf > acc) else 0.0
    return o^


def abstain(z: Mat[F64], y: Mat[I32], t: Float64, max_err: Float64, fixed: Mat[F64]) raises -> Mat[F64]:
    """[threshold, coverage, error of the accepted]. Without `fixed`, the lowest threshold whose accepted set (conf >= thr)
    has error <= max_err; none: threshold 2, coverage 0, error 0."""
    _check_logits(z, y, "calAbstain")
    var cc = conf_correct(z, y, t)
    var n = z.rows
    var o = Mat[F64](1, 3, 1, False)
    var thr = Float64(2)
    if fixed.rows > 0:
        thr = fixed.data[0]
    else:
        var order = List[Int]()
        for i in range(n):
            order.append(i)

        def higher(p: Int, q: Int) {imm} -> Bool:
            return cc.data[2 * p] > cc.data[2 * q] or (cc.data[2 * p] == cc.data[2 * q] and p < q)

        sort(Span(order), higher)
        var right = Float64(0)
        for k in range(1, n + 1):
            right += cc.data[2 * order[k - 1] + 1]
            var tie = k < n and cc.data[2 * order[k]] == cc.data[2 * order[k - 1]]
            if not tie and 1.0 - right / Float64(k) <= max_err:
                thr = cc.data[2 * order[k - 1]]
    var kept = 0
    var right = Float64(0)
    for i in range(n):
        if cc.data[2 * i] >= thr:
            kept += 1
            right += cc.data[2 * i + 1]
    o.data[0] = thr
    o.data[1] = Float64(kept) / Float64(n)
    o.data[2] = (1.0 - right / Float64(kept)) if kept > 0 else 0.0
    return o^


def run(mut a: Args) raises -> Bool:
    if a.op == "calDm":
        if len(a.ins) < 2:
            raise Error("mojocv: calDm needs 2 input file(s)")
        var c = load[F64](a.ins[0])
        var al = load[F64](a.ins[1])
        var o = Mat[F64](0, 0)
        while a.again():
            o = dm_nll(c, al)
        save(o, a.out)
    elif a.op == "calFitDm":
        if len(a.ins) < 2:
            raise Error("mojocv: calFitDm needs 2 input file(s)")
        var c = load[F64](a.ins[0])
        var p = load[F64](a.ins[1])
        var o = Mat[F64](0, 0)
        while a.again():
            o = fit_dm(c, p)
        save(o, a.out)
    elif a.op == "calTemp" or a.op == "calEval" or a.op == "calAbstain":
        if len(a.ins) < 2:
            raise Error("mojocv: " + a.op + " needs 2 input file(s)")
        var z = load[F64](a.ins[0])
        var y = load[I32](a.ins[1])
        var fixed = load[F64](a.ins[2]) if len(a.ins) > 2 else Mat[F64](0, 0)
        var o = Mat[F64](0, 0)
        while a.again():
            if a.op == "calTemp":
                o = fit_temperature(z, y)
            elif a.op == "calEval":
                o = ece_report(z, y, fixed.data[0] if fixed.rows > 0 else a.f("T", 1.0), a.i("bins", 15), a.f("max_ece", 0.05))
            else:
                o = abstain(z, y, a.f("T", 1.0), a.f("max_err", 0.1), fixed)
        save(o, a.out)
    else:
        return False
    return True
