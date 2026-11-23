# CPU float32 NCHW ops for the SCRFD and ArcFace graphs, and a runner that executes an ONNX Model's
# nodes in file order (ONNX stores them topologically sorted). Batch is 1.
from std.collections import Dict
from std.math import exp, tanh, sqrt
from std.os import getenv
from max.algorithm import parallelize
from gpunet.onnx import Model, Node, Tensor

comptime W = 16


struct Arr(Copyable, Movable):
    var shape: List[Int]
    var d: List[Float32]

    def __init__(out self, var shape: List[Int]):
        var n = 1
        for s in shape:
            n *= s
        self.shape = shape^
        self.d = List[Float32](length=n, fill=0.0)

    def __init__(out self, var shape: List[Int], var d: List[Float32]):
        self.shape = shape^
        self.d = d^

    def numel(self) -> Int:
        return len(self.d)


def gemm(a: UnsafePointer[Float32, _], b: UnsafePointer[Float32, _], c: UnsafePointer[mut=True, Float32, _], m: Int, k: Int, n: Int):
    """C[m, n] = A[m, k] @ B[k, n], row-major; threads over rows of C, SIMD over its columns."""
    var nv = n // W * W

    def rows(t: Int) {imm}:
        var per = (m + 63) // 64
        for i in range(t * per, min(m, (t + 1) * per)):
            var ci = c + i * n
            for j in range(n):
                ci[j] = 0.0
            for kk in range(k):
                var av = a[i * k + kk]
                if av == 0.0:
                    continue
                var bk = b + kk * n
                var j = 0
                while j < nv:
                    ci.store(j, ci.load[width=W](j) + av * bk.load[width=W](j))
                    j += W
                while j < n:
                    ci[j] += av * bk[j]
                    j += 1

    parallelize(rows, 64)


def conv(x: Arr, w: Tensor, bias: Int, model: Model, node: Node) raises -> Arr:
    """Conv, group 1, any kernel, stride, pad and dilation; via im2col + gemm."""
    var cin = x.shape[1]
    var h = x.shape[2]
    var wd = x.shape[3]
    var cout = w.dims[0]
    var kh = w.dims[2]
    var kw = w.dims[3]
    if node.int_attr("group", 1) != 1 or w.dims[1] != cin:
        raise Error("conv: grouped conv not supported in " + node.name)
    var st = node.ints_attr("strides")
    var pd = node.ints_attr("pads")
    var dl = node.ints_attr("dilations")
    var sh = st[0] if len(st) > 0 else 1
    var sw = st[1] if len(st) > 1 else sh
    var pt = pd[0] if len(pd) > 0 else 0
    var pl = pd[1] if len(pd) > 1 else 0
    var pb = pd[2] if len(pd) > 2 else pt
    var pr = pd[3] if len(pd) > 3 else pl
    var dh = dl[0] if len(dl) > 0 else 1
    var dw = dl[1] if len(dl) > 1 else dh
    var ho = (h + pt + pb - dh * (kh - 1) - 1) // sh + 1
    var wo = (wd + pl + pr - dw * (kw - 1) - 1) // sw + 1
    var kk = cin * kh * kw
    var n = ho * wo
    var col = List[Float32](length=kk * n, fill=0.0)
    var xp = x.d.unsafe_ptr()
    var cp = col.unsafe_ptr()
    for c in range(cin):
        for i in range(kh):
            for j in range(kw):
                var row = cp + ((c * kh + i) * kw + j) * n
                for oy in range(ho):
                    var iy = oy * sh - pt + i * dh
                    if iy < 0 or iy >= h:
                        continue
                    var src = xp + (c * h + iy) * wd
                    for ox in range(wo):
                        var ix = ox * sw - pl + j * dw
                        if ix >= 0 and ix < wd:
                            row[oy * wo + ox] = src[ix]
    var out = Arr([1, cout, ho, wo])
    gemm(w.f.unsafe_ptr(), cp, out.d.unsafe_ptr(), cout, kk, n)
    if bias >= 0:
        var b = model.inits[bias].f.unsafe_ptr()
        for o in range(cout):
            var bo = b[o]
            for p in range(n):
                out.d[o * n + p] += bo
    return out^


def pool(x: Arr, node: Node, is_max: Bool) raises -> Arr:
    var c = x.shape[1]
    var h = x.shape[2]
    var wd = x.shape[3]
    var ks = node.ints_attr("kernel_shape")
    var st = node.ints_attr("strides")
    var pd = node.ints_attr("pads")
    var kh = ks[0]
    var kw = ks[1]
    var sh = st[0] if len(st) > 0 else 1
    var sw = st[1] if len(st) > 1 else sh
    var pt = pd[0] if len(pd) > 0 else 0
    var pl = pd[1] if len(pd) > 1 else 0
    var pb = pd[2] if len(pd) > 2 else pt
    var pr = pd[3] if len(pd) > 3 else pl
    var ceil = node.int_attr("ceil_mode", 0)
    var incl = node.int_attr("count_include_pad", 0)
    var ho = (h + pt + pb - kh + (sh - 1 if ceil else 0)) // sh + 1
    var wo = (wd + pl + pr - kw + (sw - 1 if ceil else 0)) // sw + 1
    var out = Arr([1, c, ho, wo])
    for ch in range(c):
        for oy in range(ho):
            for ox in range(wo):
                var best = Float32(-3.4e38)
                var s = Float32(0)
                var cnt = 0
                for i in range(kh):
                    for j in range(kw):
                        var iy = oy * sh - pt + i
                        var ix = ox * sw - pl + j
                        if iy >= 0 and iy < h and ix >= 0 and ix < wd:
                            var v = x.d[(ch * h + iy) * wd + ix]
                            best = max(best, v)
                            s += v
                            cnt += 1
                        elif iy < h + pb and ix < wd + pr:
                            cnt += 1 if incl else 0
                out.d[(ch * ho + oy) * wo + ox] = best if is_max else s / Float32(max(cnt, 1))
    return out^


def broadcast2[op: Int](a: Arr, b: Arr) raises -> Arr:
    """Add (op 0), Mul (op 1) or Div (op 2, a over b) with numpy broadcasting of b onto a's shape (b rank <= a rank)."""
    var r = max(len(a.shape), len(b.shape))
    var sa = List[Int](length=r, fill=1)
    var sb = List[Int](length=r, fill=1)
    for k in range(len(a.shape)):
        sa[r - len(a.shape) + k] = a.shape[k]
    for k in range(len(b.shape)):
        sb[r - len(b.shape) + k] = b.shape[k]
    var shp = List[Int]()
    for k in range(r):
        if sa[k] != sb[k] and sa[k] != 1 and sb[k] != 1:
            raise Error("broadcast: shapes do not match at dim " + String(k))
        shp.append(max(sa[k], sb[k]))
    var out = Arr(shp.copy())
    var ta = List[Int](length=r, fill=0)
    var tb = List[Int](length=r, fill=0)
    var ca = 1
    var cb = 1
    for k in range(r - 1, -1, -1):
        ta[k] = ca if sa[k] != 1 else 0
        tb[k] = cb if sb[k] != 1 else 0
        ca *= sa[k]
        cb *= sb[k]
    var same = a.numel() == out.numel() and b.numel() == out.numel()
    for e in range(out.numel()):
        var ai = e
        var bi = e
        if not same:
            ai = 0
            bi = 0
            var rem = e
            for k in range(r - 1, -1, -1):
                var c = rem % shp[k]
                rem //= shp[k]
                ai += c * ta[k]
                bi += c * tb[k]
        comptime if op == 0:
            out.d[e] = a.d[ai] + b.d[bi]
        elif op == 2:
            out.d[e] = a.d[ai] / b.d[bi]
        else:
            out.d[e] = a.d[ai] * b.d[bi]
    return out^


def resize_nearest(x: Arr, size: List[Int]) -> Arr:
    """Resize mode nearest, coordinate_transformation_mode asymmetric, nearest_mode floor."""
    var c = x.shape[1]
    var h = x.shape[2]
    var w = x.shape[3]
    var ho = size[2]
    var wo = size[3]
    var out = Arr([1, c, ho, wo])
    for ch in range(c):
        for oy in range(ho):
            var iy = min(h - 1, oy * h // ho)
            for ox in range(wo):
                out.d[(ch * ho + oy) * wo + ox] = x.d[(ch * h + iy) * w + min(w - 1, ox * w // wo)]
    return out^


def transpose(x: Arr, perm: List[Int]) -> Arr:
    var r = len(x.shape)
    var shp = List[Int]()
    for q in perm:
        shp.append(x.shape[q])
    var out = Arr(shp.copy())
    var ist = List[Int](length=r, fill=1)
    for k in range(r - 2, -1, -1):
        ist[k] = ist[k + 1] * x.shape[k + 1]
    for e in range(out.numel()):
        var rem = e
        var src = 0
        for k in range(r - 1, -1, -1):
            src += (rem % shp[k]) * ist[perm[k]]
            rem //= shp[k]
        out.d[e] = x.d[src]
    return out^


def matmul(a: Arr, b: Arr) raises -> Arr:
    """[..., m, k] @ [..., k, n]; b may be 2-D (shared by every batch of a), otherwise its batch dims equal a's."""
    var ra = len(a.shape)
    var rb = len(b.shape)
    if ra < 2 or rb < 2:
        raise Error("MatMul: rank below 2 is not supported")
    var m = a.shape[ra - 2]
    var k = a.shape[ra - 1]
    var n = b.shape[rb - 1]
    if b.shape[rb - 2] != k:
        raise Error("MatMul: inner dims " + String(k) + " and " + String(b.shape[rb - 2]) + " differ")
    var batch = a.numel() // (m * k)
    if rb > 2 and b.numel() // (k * n) != batch:
        raise Error("MatMul: batch dims differ (broadcast is not supported)")
    var shp = a.shape.copy()
    shp[ra - 1] = n
    var out = Arr(shp^)
    for i in range(batch):
        gemm(a.d.unsafe_ptr() + i * m * k, b.d.unsafe_ptr() + (i * k * n if rb > 2 else 0), out.d.unsafe_ptr() + i * m * n, m, k, n)
    return out^


def layernorm(x: Arr, scale: Arr, bias: Arr, eps: Float32, axis: Int) -> Arr:
    """ONNX LayerNormalization over dims [axis, rank): biased variance, float64 sums, scale and bias of that inner shape."""
    var r = len(x.shape)
    var ax = axis if axis >= 0 else axis + r
    var inner = 1
    for q in range(ax, r):
        inner *= x.shape[q]
    var out = Arr(x.shape.copy())
    for i in range(x.numel() // inner):
        var s = Float64(0)
        for j in range(inner):
            s += Float64(x.d[i * inner + j])
        var mu = s / Float64(inner)
        var vs = Float64(0)
        for j in range(inner):
            var dd = Float64(x.d[i * inner + j]) - mu
            vs += dd * dd
        var inv = 1.0 / sqrt(vs / Float64(inner) + Float64(eps))
        for j in range(inner):
            out.d[i * inner + j] = Float32((Float64(x.d[i * inner + j]) - mu) * inv) * scale.d[j] + bias.d[j]
    return out^


def softmax_last(x: Arr) -> Arr:
    var n = x.shape[len(x.shape) - 1]
    var out = Arr(x.shape.copy())
    for i in range(x.numel() // n):
        var mx = x.d[i * n]
        for j in range(n):
            mx = max(mx, x.d[i * n + j])
        var s = Float64(0)
        for j in range(n):
            var e = exp(Float64(x.d[i * n + j] - mx))
            out.d[i * n + j] = Float32(e)
            s += e
        for j in range(n):
            out.d[i * n + j] = Float32(Float64(out.d[i * n + j]) / s)
    return out^


def l2_last(x: Arr, keep: Bool) -> Arr:
    """ReduceL2 over the last axis."""
    var n = x.shape[len(x.shape) - 1]
    var shp = x.shape.copy()
    if keep:
        shp[len(shp) - 1] = 1
    else:
        _ = shp.pop()
    var out = Arr(shp^)
    for i in range(x.numel() // n):
        var s = Float64(0)
        for j in range(n):
            s += Float64(x.d[i * n + j]) * Float64(x.d[i * n + j])
        out.d[i] = Float32(sqrt(s))
    return out^


def needed(model: Model, targets: List[String]) -> List[Bool]:
    """Which nodes (file order) the `targets` values depend on."""
    var need = Dict[String, Bool]()
    for t in targets:
        need[t] = True
    var keep = List[Bool](length=len(model.nodes), fill=False)
    for ni in range(len(model.nodes) - 1, -1, -1):
        ref node = model.nodes[ni]
        var hit = False
        for q in node.outputs:
            if q in need:
                hit = True
        if hit:
            keep[ni] = True
            for q in node.inputs:
                need[q] = True
    return keep^


def run(model: Model, var feeds: Dict[String, Arr], targets: List[String] = List[String]()) raises -> Dict[String, Arr]:
    """Executes every node (or only those `targets` depend on); returns all values by name (graph outputs among them)."""
    var v = feeds^
    var ints = Dict[String, List[Int]]()  # shape-arithmetic values (Shape, Gather, ... outputs)
    for t in model.inits:
        if len(t.f) > 0 or t.numel() == 0:
            v[t.name] = Arr(t.dims.copy(), t.f.copy())
        else:
            ints[t.name] = t.i.copy()
    var trace = getenv("FACES_TRACE") != ""  # prints each node before it runs: the last line names a failing one
    var keep = needed(model, targets) if len(targets) > 0 else List[Bool](length=len(model.nodes), fill=True)
    for ni in range(len(model.nodes)):
        if not keep[ni]:
            continue
        ref node = model.nodes[ni]
        var op = node.op
        var o = node.outputs[0]
        if trace:
            print("node", op, node.name)
        if op == "Conv":
            var wi = model.init(node.inputs[1])
            var bi = model.init(node.inputs[2]) if len(node.inputs) > 2 else -1
            v[o] = conv(v[node.inputs[0]], model.inits[wi], bi, model, node)
        elif op == "Relu" or op == "Sigmoid":
            var x = v[node.inputs[0]].copy()
            for e in range(x.numel()):
                x.d[e] = max(x.d[e], 0.0) if op == "Relu" else 1.0 / (1.0 + exp(-x.d[e]))
            v[o] = x^
        elif op == "PRelu":
            var x = v[node.inputs[0]].copy()
            var sl = v[node.inputs[1]].d.copy()
            var hw = x.shape[2] * x.shape[3]
            for e in range(x.numel()):
                if x.d[e] < 0:
                    x.d[e] *= sl[(e // hw) % len(sl)]
            v[o] = x^
        elif op == "BatchNormalization":
            var x = v[node.inputs[0]].copy()
            var eps = Float32(1e-5)
            var k = node.attr("epsilon")
            if k >= 0:
                eps = node.attrs[k].f
            var g = v[node.inputs[1]].d.copy()
            var b = v[node.inputs[2]].d.copy()
            var mu = v[node.inputs[3]].d.copy()
            var var_ = v[node.inputs[4]].d.copy()
            var hw = x.shape[2] * x.shape[3] if len(x.shape) == 4 else 1
            for c in range(x.shape[1]):
                var s = g[c] / (var_[c] + eps) ** 0.5
                var t = b[c] - mu[c] * s
                for p in range(hw):
                    x.d[c * hw + p] = x.d[c * hw + p] * s + t
            v[o] = x^
        elif op == "Add" and node.inputs[0] in ints:  # shape arithmetic
            var a = ints[node.inputs[0]].copy()
            var b = ints[node.inputs[1]].copy()
            var r = List[Int]()
            for q in range(max(len(a), len(b))):
                r.append(a[q if len(a) > 1 else 0] + b[q if len(b) > 1 else 0])
            ints[o] = r^
        elif op == "Add":
            v[o] = broadcast2[0](v[node.inputs[0]], v[node.inputs[1]])
        elif op == "Mul" and node.inputs[0] in v and node.inputs[1] in v:
            v[o] = broadcast2[1](v[node.inputs[0]], v[node.inputs[1]])
        elif op == "MaxPool" or op == "AveragePool":
            v[o] = pool(v[node.inputs[0]], node, op == "MaxPool")
        elif op == "Flatten":
            var x = v[node.inputs[0]].copy()
            x.shape = [1, x.numel()]
            v[o] = x^
        elif op == "Gemm":
            var x = v[node.inputs[0]].copy()
            var w = model.inits[model.init(node.inputs[1])].copy()
            var tb = node.int_attr("transB", 0)
            var nout = w.dims[0] if tb else w.dims[1]
            var kin = x.numel()
            var out = Arr([1, nout])
            for j in range(nout):
                var s = Float32(0)
                for kk in range(kin):
                    s += x.d[kk] * (w.f[j * kin + kk] if tb else w.f[kk * nout + j])
                out.d[j] = s
            if len(node.inputs) > 2:
                var b = v[node.inputs[2]].d.copy()
                for j in range(nout):
                    out.d[j] += b[j]
            v[o] = out^
        elif op == "Shape" and node.inputs[0] in v:
            ints[o] = v[node.inputs[0]].shape.copy()
        elif op == "Gather" and node.inputs[0] in v:  # rows of a float table (embeddings), axis 0
            ref tab = v[node.inputs[0]]
            var ids = List[Int]()
            if node.inputs[1] in ints:
                ids = ints[node.inputs[1]].copy()
            else:
                for q in v[node.inputs[1]].d:
                    ids.append(Int(q))
            var row = tab.numel() // tab.shape[0]
            var shp = List[Int]()
            if node.inputs[1] in v:
                shp = v[node.inputs[1]].shape.copy()
            else:
                shp.append(len(ids))
            for q in range(1, len(tab.shape)):
                shp.append(tab.shape[q])
            var out = Arr(shp^)
            for r in range(len(ids)):
                var src = ids[r] if ids[r] >= 0 else ids[r] + tab.shape[0]
                for c in range(row):
                    out.d[r * row + c] = tab.d[src * row + c]
            v[o] = out^
        elif op == "Gather":
            var src = ints[node.inputs[0]].copy()
            var idx = ints[node.inputs[1]].copy()
            var r = List[Int]()
            for q in idx:
                r.append(src[q if q >= 0 else q + len(src)])
            ints[o] = r^
        elif op == "Unsqueeze" and node.inputs[0] in v:
            var x = v[node.inputs[0]].copy()
            var axes = ints[node.inputs[1]].copy() if len(node.inputs) > 1 else node.ints_attr("axes")
            var r = len(x.shape) + len(axes)
            var shp = List[Int]()
            var src = 0
            for q in range(r):
                var hit = False
                for a in axes:
                    if (a if a >= 0 else a + r) == q:
                        hit = True
                if hit:
                    shp.append(1)
                else:
                    shp.append(x.shape[src])
                    src += 1
            x.shape = shp^
            v[o] = x^
        elif op == "Unsqueeze":
            ints[o] = ints[node.inputs[0]].copy()
        elif op == "Shape" and node.inputs[0] in ints:
            ints[o] = [len(ints[node.inputs[0]])]
        elif op == "ConstantOfShape":
            ref t = node.attrs[node.attr("value")].t[0]
            var n = 1
            for q in ints[node.inputs[0]]:
                n *= q
            if len(t.f) > 0:
                var x = Arr(ints[node.inputs[0]].copy())
                for e in range(n):
                    x.d[e] = t.f[0]
                v[o] = x^
            else:
                ints[o] = List[Int](length=n, fill=t.i[0])
        elif op == "Expand" or op == "Tile":  # numpy broadcast to a shape, or repeat along each axis
            ref x = v[node.inputs[0]]
            var want = ints[node.inputs[1]].copy()
            var r = max(len(x.shape), len(want))
            var xs = List[Int](length=r, fill=1)
            for q in range(len(x.shape)):
                xs[r - len(x.shape) + q] = x.shape[q]
            var ws = List[Int](length=r, fill=1)
            for q in range(len(want)):
                ws[r - len(want) + q] = want[q]
            var shp = List[Int]()
            for q in range(r):
                shp.append(xs[q] * ws[q] if op == "Tile" else max(xs[q], ws[q]))
            var out = Arr(shp.copy())
            var st = List[Int](length=r, fill=1)
            for q in range(r - 2, -1, -1):
                st[q] = st[q + 1] * xs[q + 1]
            for e in range(out.numel()):
                var rem = e
                var src = 0
                for q in range(r - 1, -1, -1):
                    var c = rem % shp[q]
                    rem //= shp[q]
                    src += (c % xs[q] if op == "Tile" else (0 if xs[q] == 1 else c)) * st[q]
                out.d[e] = x.d[src]
            v[o] = out^
        elif op == "Cast":  # to: 1 float, 6 int32, 7 int64; shape arithmetic stays in `ints`
            var to = node.int_attr("to", 1)
            if node.inputs[0] in ints:
                if to == 1:
                    var x = Arr([len(ints[node.inputs[0]])])
                    for e in range(x.numel()):
                        x.d[e] = Float32(ints[node.inputs[0]][e])
                    v[o] = x^
                else:
                    ints[o] = ints[node.inputs[0]].copy()
            elif to == 1:
                v[o] = v[node.inputs[0]].copy()
            else:
                var r = List[Int]()
                for q in v[node.inputs[0]].d:
                    r.append(Int(q))
                ints[o] = r^
        elif op == "Squeeze":
            if node.inputs[0] in ints:
                ints[o] = ints[node.inputs[0]].copy()
            else:
                var x = v[node.inputs[0]].copy()
                var axes = ints[node.inputs[1]].copy() if len(node.inputs) > 1 else node.ints_attr("axes")
                var shp = List[Int]()
                for q in range(len(x.shape)):
                    var hit = len(axes) == 0 and x.shape[q] == 1
                    for a in axes:
                        if (a if a >= 0 else a + len(x.shape)) == q:
                            hit = True
                    if not hit:
                        shp.append(x.shape[q])
                x.shape = shp^
                v[o] = x^
        elif op == "Constant":
            ref t = node.attrs[node.attr("value")].t[0]
            if len(t.f) > 0:
                v[o] = Arr(t.dims.copy(), t.f.copy())
            else:
                ints[o] = t.i.copy()
        elif op == "MatMul":
            v[o] = matmul(v[node.inputs[0]], v[node.inputs[1]])
        elif op == "LayerNormalization":
            var eps = node.attrs[node.attr("epsilon")].f if node.attr("epsilon") >= 0 else Float32(1e-5)
            v[o] = layernorm(v[node.inputs[0]], v[node.inputs[1]], v[node.inputs[2]], eps, node.int_attr("axis", -1))
        elif op == "Softmax":
            var ax = node.int_attr("axis", -1)
            if ax != -1 and ax != len(v[node.inputs[0]].shape) - 1:
                raise Error("Softmax: only the last axis is supported (" + node.name + ")")
            v[o] = softmax_last(v[node.inputs[0]])
        elif op == "Tanh" or op == "Exp":
            var x = v[node.inputs[0]].copy()
            for e in range(x.numel()):
                x.d[e] = Float32(tanh(Float64(x.d[e]))) if op == "Tanh" else Float32(exp(Float64(x.d[e])))
            v[o] = x^
        elif op == "ReduceL2":
            var ax = node.ints_attr("axes")
            if len(ax) > 0 and ax[0] != -1 and ax[0] != len(v[node.inputs[0]].shape) - 1:
                raise Error("ReduceL2: only the last axis is supported (" + node.name + ")")
            v[o] = l2_last(v[node.inputs[0]], node.int_attr("keepdims", 1) == 1)
        elif op == "Mod":  # shape arithmetic, sign of the divisor (fmod = 0)
            var a = ints[node.inputs[0]].copy()
            var b = ints[node.inputs[1]].copy()
            var r = List[Int]()
            for q in range(max(len(a), len(b))):
                r.append(a[q if len(a) > 1 else 0] % b[q if len(b) > 1 else 0])
            ints[o] = r^
        elif op == "Div" and node.inputs[0] in ints:  # shape arithmetic, integer division
            var a = ints[node.inputs[0]].copy()
            var b = ints[node.inputs[1]].copy()
            var r = List[Int]()
            for q in range(max(len(a), len(b))):
                r.append(a[q if len(a) > 1 else 0] // b[q if len(b) > 1 else 0])
            ints[o] = r^
        elif op == "Div":
            if v[node.inputs[0]].numel() < v[node.inputs[1]].numel():
                raise Error("Div: divisor larger than the dividend is not supported (" + node.name + ")")
            v[o] = broadcast2[2](v[node.inputs[0]], v[node.inputs[1]])
        elif op == "Mul":  # both operands are shape arithmetic
            var a = ints[node.inputs[0]].copy()
            var b = ints[node.inputs[1]].copy()
            var r = List[Int]()
            for q in range(max(len(a), len(b))):
                r.append(a[q if len(a) > 1 else 0] * b[q if len(b) > 1 else 0])
            ints[o] = r^
        elif op == "Slice" and node.inputs[0] in v:  # float tensor, step 1
            ref x = v[node.inputs[0]]
            var starts = ints[node.inputs[1]].copy()
            var ends = ints[node.inputs[2]].copy()
            var axes = ints[node.inputs[3]].copy() if len(node.inputs) > 3 and node.inputs[3] != "" else List[Int]()
            if len(node.inputs) > 4 and node.inputs[4] != "":
                for q in ints[node.inputs[4]]:
                    if q != 1:
                        raise Error("Slice: step " + String(q) + " is not supported (" + node.name + ")")
            if len(axes) == 0:
                for q in range(len(starts)):
                    axes.append(q)
            var lo = List[Int](length=len(x.shape), fill=0)
            var hi = x.shape.copy()
            for q in range(len(axes)):
                var ax = axes[q] if axes[q] >= 0 else axes[q] + len(x.shape)
                var dim = x.shape[ax]
                var s0 = starts[q] if starts[q] >= 0 else starts[q] + dim
                var e0 = ends[q] if ends[q] >= 0 else ends[q] + dim
                lo[ax] = max(0, min(s0, dim))
                hi[ax] = max(lo[ax], min(e0, dim))
            var shp = List[Int]()
            for q in range(len(x.shape)):
                shp.append(hi[q] - lo[q])
            var out = Arr(shp.copy())
            var st = List[Int](length=len(x.shape), fill=1)
            for q in range(len(x.shape) - 2, -1, -1):
                st[q] = st[q + 1] * x.shape[q + 1]
            for e in range(out.numel()):
                var rem = e
                var src = 0
                for q in range(len(shp) - 1, -1, -1):
                    src += (rem % shp[q] + lo[q]) * st[q]
                    rem //= shp[q]
                out.d[e] = x.d[src]
            v[o] = out^
        elif op == "Slice":
            var src = ints[node.inputs[0]].copy()
            var st = ints[node.inputs[1]][0]
            var en = ints[node.inputs[2]][0]
            st = max(0, st + len(src) if st < 0 else st)  # negative indices count from the end
            en = min(len(src), en + len(src) if en < 0 else en)
            var r = List[Int]()
            for q in range(st, en):
                r.append(src[q])
            ints[o] = r^
        elif op == "Concat" and node.inputs[0] in ints:
            var r = List[Int]()
            for name in node.inputs:
                r.extend(ints[name].copy())
            ints[o] = r^
        elif op == "Resize":
            v[o] = resize_nearest(v[node.inputs[0]], ints[node.inputs[3]])
        elif op == "Transpose":
            v[o] = transpose(v[node.inputs[0]], node.ints_attr("perm"))
        elif op == "Reshape" and node.inputs[0] in ints:  # a shape vector reshaped to another 1-D shape
            ints[o] = ints[node.inputs[0]].copy()
        elif op == "Reshape":
            var x = v[node.inputs[0]].copy()
            var want = ints[node.inputs[1]].copy()
            var known = 1
            var neg = -1
            for q in range(len(want)):
                if want[q] == 0:
                    want[q] = x.shape[q]
                if want[q] == -1:
                    neg = q
                else:
                    known *= want[q]
            if neg >= 0:
                want[neg] = x.numel() // known
            x.shape = want^
            v[o] = x^
        else:
            raise Error("run: op not supported yet: " + op + " (" + node.name + ")")
    return v^
