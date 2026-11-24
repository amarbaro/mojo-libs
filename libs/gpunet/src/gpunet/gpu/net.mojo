# GPU runner for the buffalo_l graphs on gfx1100, the CPU runner's contract: float32 NCHW feeds in, the
# graph outputs out by name. Weights are uploaded once and stay resident; Conv = im2col + GEMM (fp32
# regtile, or fp16 WMMA with fp32 accumulate) + a bias/Relu epilogue; every other float op runs on the
# device, shape arithmetic on the host. A dead activation goes back to a pool keyed by its size, so a
# warm run allocates nothing. Batch N >= 1 for every op but the SCRFD heads' reshapes.
from std.collections import Dict
from std.math import ceildiv
from max.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, row_major
from gpunet.onnx import Model, Node
from gpunet.nn import Arr, needed
from gpunet.gpu.kernels import F, P, THREADS, grid, half_k, im2col_k, epilogue_k, act_k, chan_k, bcast_k, pool_k, resize_k, transpose_k, ln_k, softmax_k, l2_k, rows_k, bgather_k
from gpunet.gpu.gemm32 import amar_matmul_regtile, BM, BN, TM, TN
from gpunet.gpu.gemm16 import amar_matmul_wmma_lds, BLK_M, BLK_N, NTHREADS

comptime B32 = DeviceBuffer[DType.float32]
comptime B16 = DeviceBuffer[DType.float16]
comptime H = MutPointer[Float16, MutUntrackedOrigin]
comptime COL_CAP = 1 << 23  # im2col elements per chunk: a batch of large maps runs in image chunks

# node kinds
comptime CONV = 0
comptime RELU = 1
comptime SIGMOID = 2
comptime PRELU = 3
comptime BN_ = 4
comptime ADD = 5
comptime MUL = 6
comptime MAXPOOL = 7
comptime AVGPOOL = 8
comptime FLATTEN = 9
comptime GEMM = 10
comptime SHAPE = 11
comptime GATHER = 12
comptime UNSQUEEZE = 13
comptime SLICE = 14
comptime CONCAT = 15
comptime RESIZE = 16
comptime TRANSPOSE = 17
comptime RESHAPE = 18
comptime ALIAS = 19  # a Relu folded into the Conv before it
comptime MATMUL = 20
comptime LNORM = 21
comptime SOFTMAX = 22
comptime TANH = 23
comptime EXP = 24
comptime L2 = 25
comptime DIV = 26
comptime BGATHER = 27  # Slice, Expand, Tile of a float tensor
comptime CONSTANT = 28
comptime CAST = 29
comptime SQUEEZE = 30
comptime MODI = 31
comptime COF = 32  # ConstantOfShape (integer)
comptime SKIP = -1  # not needed for the requested outputs


def fp(b: B32) -> F:
    return F(unsafe_from_address=Int(b.unsafe_ptr()))


def numel(s: List[Int]) -> Int:
    var n = 1
    for d in s:
        n *= d
    return n


def up8(n: Int) -> Int:
    return (n + 7) // 8 * 8


struct Val(Copyable, Movable):
    var shape: List[Int]
    var buf: B32

    def __init__(out self, var shape: List[Int], buf: B32):
        self.shape = shape^
        self.buf = buf


struct GpuNet(Movable):
    var ctx: DeviceContext
    var fp16: Bool
    var nodes: List[Node]
    var kind: List[Int]
    var aux: List[Int]  # per node: index into convs / chans / fcs
    var last: Dict[String, Int]  # value name -> index of its last consuming node
    var outputs: List[String]
    var inputs: List[String]
    var ints0: Dict[String, List[Int]]
    var res: Dict[String, Val]  # resident float initializers read as values
    var mw16: Dict[String, B16]  # fp16 copies of rank-2 MatMul weights (fp16 arm)
    var cw32: List[B32]
    var cw16: List[B16]
    var cbias: List[B32]
    var cgeo: List[P]  # cin kh kw sh sw pt pl pb pr dh dw cout K Kp relu
    var cs: List[B32]  # PRelu slope or BN scale
    var ct: List[B32]  # BN shift
    var cn: List[Int]  # channel count of cs
    var fcw: List[B32]  # Gemm weight as [K, nout]
    var fcn: List[Int]
    var free: Dict[Int, List[B32]]
    var col32: B32
    var col16: B16
    var cbuf: B32
    var bytes: Int  # device bytes this runner allocated (weights, pool, scratch)
    var pend: List[Arr]
    var pend_vals: List[Val]
    var hold: Dict[String, Arr]

    def __init__(out self, ctx: DeviceContext, model: Model, fp16: Bool, targets: List[String] = List[String]()) raises:
        """With `targets`, only the nodes those values depend on are built and run, and they are the outputs."""
        self.ctx = ctx
        self.fp16 = fp16
        self.nodes = model.nodes.copy()
        self.kind = List[Int]()
        self.aux = List[Int]()
        self.last = Dict[String, Int]()
        self.outputs = targets.copy() if len(targets) > 0 else model.outputs.copy()
        var keep = needed(model, targets) if len(targets) > 0 else List[Bool](length=len(model.nodes), fill=True)
        self.inputs = model.inputs.copy()
        self.ints0 = Dict[String, List[Int]]()
        self.res = Dict[String, Val]()
        self.mw16 = Dict[String, B16]()
        self.cw32 = List[B32]()
        self.cw16 = List[B16]()
        self.cbias = List[B32]()
        self.cgeo = List[P]()
        self.cs = List[B32]()
        self.ct = List[B32]()
        self.cn = List[Int]()
        self.fcw = List[B32]()
        self.fcn = List[Int]()
        self.free = Dict[Int, List[B32]]()
        self.bytes = 0
        self.col32 = ctx.enqueue_create_buffer[DType.float32](1)
        self.col16 = ctx.enqueue_create_buffer[DType.float16](1)
        self.cbuf = ctx.enqueue_create_buffer[DType.float32](1)
        self.pend = List[Arr]()
        self.pend_vals = List[Val]()
        self.hold = Dict[String, Arr]()
        for t in model.inits:
            if len(t.f) == 0 and t.numel() > 0:
                self.ints0[t.name] = t.i.copy()
        for i in range(len(self.nodes)):
            for name in self.nodes[i].inputs:
                self.last[name] = i
        for i in range(len(self.nodes)):
            ref node = model.nodes[i]
            var op = node.op
            var k = -1
            var a = 0
            if not keep[i]:
                self.kind.append(SKIP)
                self.aux.append(0)
                continue
            for name in node.inputs:  # float initializers read as values (MatMul weights, LayerNorm scale, tables)
                var q = model.init(name)
                if q >= 0 and len(model.inits[q].f) > 0 and name not in self.res and op != "Conv" and op != "BatchNormalization" and op != "PRelu" and op != "Gemm":
                    self.res[name] = Val(model.inits[q].dims.copy(), self.up(model.inits[q].f))
                    ref d = model.inits[q].dims
                    if self.fp16 and op == "MatMul" and name == node.inputs[1] and len(d) == 2 and d[0] % 8 == 0 and d[1] % 8 == 0:
                        self.mw16[name] = self._h16(model.inits[q].f, d[0], d[1], d[1])
            if op == "Conv":
                k = CONV
                a = len(self.cgeo)
                self._conv(model, node)
            elif op == "Relu":
                k = RELU
                if i > 0 and self.kind[i - 1] == CONV and self.nodes[i - 1].outputs[0] == node.inputs[0] and self.last[node.inputs[0]] == i and node.inputs[0] not in self.outputs:
                    k = ALIAS
                    self.cgeo[self.aux[i - 1]][14] = 1
            elif op == "Sigmoid":
                k = SIGMOID
            elif op == "PRelu":
                k = PRELU
                a = len(self.cs)
                var sl = model.inits[self._init(model, node.inputs[1])].f.copy()
                self.cn.append(len(sl))
                self.cs.append(self.up(sl))
                self.ct.append(self.cs[a])
            elif op == "BatchNormalization":
                k = BN_
                a = len(self.cs)
                var eps = Float32(1e-5)
                var q = node.attr("epsilon")
                if q >= 0:
                    eps = node.attrs[q].f
                var g = model.inits[self._init(model, node.inputs[1])].f.copy()
                var b = model.inits[self._init(model, node.inputs[2])].f.copy()
                var mu = model.inits[self._init(model, node.inputs[3])].f.copy()
                var v = model.inits[self._init(model, node.inputs[4])].f.copy()
                var s = List[Float32](length=len(g), fill=0.0)
                var t = List[Float32](length=len(g), fill=0.0)
                for c in range(len(g)):
                    s[c] = g[c] / (v[c] + eps) ** 0.5  # as nn.mojo, so both runners fold alike
                    t[c] = b[c] - mu[c] * s[c]
                self.cn.append(len(g))
                self.cs.append(self.up(s))
                self.ct.append(self.up(t))
            elif op == "Add" or op == "Mul":
                k = ADD if op == "Add" else MUL
                for name in node.inputs:
                    var q = model.init(name)
                    if q >= 0 and name not in self.res:
                        self.res[name] = Val(model.inits[q].dims.copy(), self.up(model.inits[q].f))
            elif op == "MaxPool" or op == "AveragePool":
                k = MAXPOOL if op == "MaxPool" else AVGPOOL
            elif op == "Flatten":
                k = FLATTEN
            elif op == "Gemm":
                k = GEMM
                a = len(self.fcw)
                ref w = model.inits[self._init(model, node.inputs[1])]
                var tb = node.int_attr("transB", 0)
                var nout = w.dims[0] if tb else w.dims[1]
                var kin = w.dims[1] if tb else w.dims[0]
                var wt = List[Float32](length=kin * nout, fill=0.0)
                for j in range(nout):
                    for q in range(kin):
                        wt[q * nout + j] = w.f[j * kin + q] if tb else w.f[q * nout + j]
                self.fcw.append(self.up(wt))
                self.fcn.append(nout)
                if len(node.inputs) > 2:
                    var q = self._init(model, node.inputs[2])
                    self.res[node.inputs[2]] = Val(model.inits[q].dims.copy(), self.up(model.inits[q].f))
            elif op == "Shape":
                k = SHAPE
            elif op == "Gather":
                k = GATHER
            elif op == "Unsqueeze":
                k = UNSQUEEZE
            elif op == "Slice":
                k = SLICE
            elif op == "Concat":
                k = CONCAT
            elif op == "Resize":
                k = RESIZE
            elif op == "Transpose":
                k = TRANSPOSE
            elif op == "Reshape":
                k = RESHAPE
            elif op == "MatMul":
                k = MATMUL
            elif op == "LayerNormalization":
                k = LNORM
            elif op == "Softmax":
                k = SOFTMAX
            elif op == "Tanh":
                k = TANH
            elif op == "Exp":
                k = EXP
            elif op == "ReduceL2":
                k = L2
            elif op == "Div":
                k = DIV
            elif op == "Expand" or op == "Tile":
                k = BGATHER
            elif op == "Cast":
                k = CAST
            elif op == "Squeeze":
                k = SQUEEZE
            elif op == "Mod":
                k = MODI
            elif op == "ConstantOfShape":
                k = COF
            elif op == "Constant":
                k = CONSTANT
                ref t = node.attrs[node.attr("value")].t[0]
                if len(t.f) > 0:
                    self.res[node.outputs[0]] = Val(t.dims.copy(), self.up(t.f))
                else:
                    self.ints0[node.outputs[0]] = t.i.copy()
            else:
                raise Error("gpu: op not supported yet: " + op + " (" + node.name + ")")
            self.kind.append(k)
            self.aux.append(a)
        self.ctx.synchronize()

    def _init(self, model: Model, name: String) raises -> Int:
        var q = model.init(name)
        if q < 0:
            raise Error("gpu: expected an initializer: " + name)
        return q

    def up(mut self, d: List[Float32]) raises -> B32:
        var b = self.ctx.enqueue_create_buffer[DType.float32](max(len(d), 1))
        self.bytes += max(len(d), 1) * 4
        if len(d) > 0:
            self.ctx.enqueue_copy(dst_buf=b, src_ptr=d.unsafe_ptr())
        self.ctx.synchronize()
        return b

    def _conv(mut self, model: Model, node: Node) raises:
        ref w = model.inits[self._init(model, node.inputs[1])]
        if node.int_attr("group", 1) != 1:
            raise Error("gpu: grouped conv not supported in " + node.name)
        var st = node.ints_attr("strides")
        var pd = node.ints_attr("pads")
        var dl = node.ints_attr("dilations")
        var g = P(0)
        g[0] = Int32(w.dims[1])
        g[1] = Int32(w.dims[2])
        g[2] = Int32(w.dims[3])
        g[3] = Int32(st[0] if len(st) > 0 else 1)
        g[4] = Int32(st[1] if len(st) > 1 else Int(g[3]))
        g[5] = Int32(pd[0] if len(pd) > 0 else 0)
        g[6] = Int32(pd[1] if len(pd) > 1 else 0)
        g[7] = Int32(pd[2] if len(pd) > 2 else Int(g[5]))
        g[8] = Int32(pd[3] if len(pd) > 3 else Int(g[6]))
        g[9] = Int32(dl[0] if len(dl) > 0 else 1)
        g[10] = Int32(dl[1] if len(dl) > 1 else Int(g[9]))
        var cout = w.dims[0]
        var kk = w.dims[1] * w.dims[2] * w.dims[3]
        var kp = up8(kk)
        g[11] = Int32(cout)
        g[12] = Int32(kk)
        g[13] = Int32(kp)
        self.cgeo.append(g)
        if not self.fp16:  # only the arm's own weights go to the device
            self.cw32.append(self.up(w.f))
            self.cw16.append(self.ctx.enqueue_create_buffer[DType.float16](1))
        else:
            self.cw32.append(self.ctx.enqueue_create_buffer[DType.float32](1))
            self.cw16.append(self._h16(w.f, cout, kk, kp))
        if len(node.inputs) > 2:
            self.cbias.append(self.up(model.inits[self._init(model, node.inputs[2])].f))
        else:
            self.cbias.append(self.up(List[Float32](length=cout, fill=0.0)))

    def _h16(mut self, f: List[Float32], cout: Int, kk: Int, kp: Int) raises -> B16:
        """[cout, kk] fp32 weights as [cout, kp] fp16, rows zero-padded so WMMA's 8-wide loads stay aligned."""
        var h = List[Float16](length=cout * kp, fill=0.0)
        for o in range(cout):
            for q in range(kk):
                h[o * kp + q] = f[o * kk + q].cast[DType.float16]()
        var b16 = self.ctx.enqueue_create_buffer[DType.float16](cout * kp)
        self.bytes += cout * kp * 2
        self.ctx.enqueue_copy(dst_buf=b16, src_ptr=h.unsafe_ptr())
        self.ctx.synchronize()
        return b16

    def take(mut self, n: Int) raises -> B32:
        if n in self.free and len(self.free[n]) > 0:
            return self.free[n].pop()
        self.bytes += n * 4
        return self.ctx.enqueue_create_buffer[DType.float32](n)

    def give(mut self, b: B32):
        var n = len(b)
        if n not in self.free:
            self.free[n] = List[B32]()
        try:
            self.free[n].append(b)
        except:
            pass

    def _grow32(mut self, n: Int, scratch_c: Bool) raises:
        """Scratch grows only on a first run; sync so no queued kernel still reads the old one."""
        var cur = len(self.cbuf) if scratch_c else len(self.col32)
        if n <= cur:
            return
        self.ctx.synchronize()
        self.bytes += (n - cur) * 4
        if scratch_c:
            self.cbuf = self.ctx.enqueue_create_buffer[DType.float32](n)
        else:
            self.col32 = self.ctx.enqueue_create_buffer[DType.float32](n)

    def _grow16(mut self, n: Int) raises:
        var cur = len(self.col16)
        if n <= cur:
            return
        self.ctx.synchronize()
        self.bytes += (n - cur) * 2
        self.col16 = self.ctx.enqueue_create_buffer[DType.float16](n)

    def gemm32(self, a: B32, b: B32, c: B32, m: Int, k: Int, n: Int) raises:
        """C[m, n] = A[m, k] @ B[k, n], row-major fp32."""
        var la = row_major(m, k)
        var lb = row_major(k, n)
        var lc = row_major(m, n)
        comptime kern = amar_matmul_regtile[type_of(la), type_of(lb), type_of(lc)]
        self.ctx.enqueue_function[kern](TileTensor(a, la), TileTensor(b, lb), TileTensor(c, lc), Int32(m), Int32(n), Int32(k),
            grid_dim=(ceildiv(n, BN), ceildiv(m, BM)), block_dim=(BN // TN, BM // TM))

    def gemm16(self, a: B16, b: B16, c: B32, m: Int, k: Int, n: Int) raises:
        var la = row_major(m, k)
        var lb = row_major(k, n)
        var lc = row_major(m, n)
        comptime kern = amar_matmul_wmma_lds[type_of(la), type_of(lb), type_of(lc)]
        self.ctx.enqueue_function[kern](TileTensor(a, la), TileTensor(b, lb), TileTensor(c, lc), Int32(m), Int32(n), Int32(k),
            grid_dim=(ceildiv(n, BLK_N), ceildiv(m, BLK_M)), block_dim=NTHREADS)

    def conv(mut self, ci: Int, x: Val) raises -> Val:
        var g = self.cgeo[ci]
        var nb = x.shape[0]
        var h = x.shape[2]
        var w = x.shape[3]
        if x.shape[1] != Int(g[0]):
            raise Error("gpu: conv input channels")
        var kh = Int(g[1])
        var kw = Int(g[2])
        var ho = (h + Int(g[5]) + Int(g[7]) - Int(g[9]) * (kh - 1) - 1) // Int(g[3]) + 1
        var wo = (w + Int(g[6]) + Int(g[8]) - Int(g[10]) * (kw - 1) - 1) // Int(g[4]) + 1
        var cout = Int(g[11])
        var kk = Int(g[12])
        var kp = Int(g[13]) if self.fp16 else kk
        var hw = ho * wo
        var y = self.take(nb * cout * hw)
        var cb = max(1, min(nb, COL_CAP // (kp * hw)))  # images per im2col chunk
        var p = P(0)
        p[0] = g[0]
        p[1] = Int32(h)
        p[2] = Int32(w)
        p[3] = g[1]
        p[4] = g[2]
        p[5] = g[3]
        p[6] = g[4]
        p[7] = g[5]
        p[8] = g[6]
        p[9] = g[9]
        p[10] = g[10]
        p[11] = Int32(ho)
        p[12] = Int32(wo)
        p[13] = Int32(kp)
        var b0 = 0
        while b0 < nb:
            var cn = min(cb, nb - b0)
            var np_ = up8(cn * hw) if self.fp16 else cn * hw
            var direct = nb == 1 and np_ == hw  # the GEMM writes NCHW itself; the epilogue adds bias in place
            if not direct:
                self._grow32(cout * np_, True)
            var c = y if direct else self.cbuf
            var xo = F(unsafe_from_address=Int(x.buf.unsafe_ptr()) + b0 * Int(g[0]) * h * w * 4)
            var yo = F(unsafe_from_address=Int(y.unsafe_ptr()) + b0 * cout * hw * 4)
            p[14] = Int32(np_)
            p[15] = Int32(cn)
            if self.fp16:
                self._grow16(kp * np_)
                var hp = H(unsafe_from_address=Int(self.col16.unsafe_ptr()))
                self.ctx.enqueue_function[im2col_k[DType.float16]](xo, hp, p, grid_dim=grid(kp * np_), block_dim=THREADS)
                self.gemm16(self.cw16[ci], self.col16, c, cout, kp, np_)
            else:
                var plain = kh == 1 and kw == 1 and g[3] == 1 and g[4] == 1 and g[5] == 0 and g[6] == 0 and g[7] == 0 and g[8] == 0 and nb == 1
                if plain:  # 1x1, stride 1, no pad: the input already is the [K, HW] matrix
                    self.gemm32(self.cw32[ci], x.buf, c, cout, kk, np_)
                else:
                    self._grow32(kk * np_, False)
                    self.ctx.enqueue_function[im2col_k[DType.float32]](xo, fp(self.col32), p, grid_dim=grid(kk * np_), block_dim=THREADS)
                    self.gemm32(self.cw32[ci], self.col32, c, cout, kk, np_)
            var e = P(0)
            e[0] = Int32(cout)
            e[1] = Int32(cn)
            e[2] = Int32(hw)
            e[3] = Int32(np_)
            e[4] = g[14]
            self.ctx.enqueue_function[epilogue_k](fp(c), fp(self.cbias[ci]), yo, e, grid_dim=grid(cn * cout * hw), block_dim=THREADS)
            b0 += cn
        return Val([nb, cout, ho, wo], y)

    def submit(mut self, var feeds: Dict[String, Arr]) raises:
        """Enqueues the whole graph and the output downloads; collect() waits for them."""
        var vals = Dict[String, Val]()
        var ints = self.ints0.copy()
        for name in self.inputs:
            if name not in feeds:  # a graph input the requested outputs do not depend on
                continue
            ref f = feeds[name]
            var b = self.take(f.numel())
            self.ctx.enqueue_copy(dst_buf=b, src_ptr=f.d.unsafe_ptr())
            vals[name] = Val(f.shape.copy(), b)
        self.hold = feeds^  # host feeds live until collect(): the copies above are async
        for i in range(len(self.nodes)):
            var k = self.kind[i]
            if k == SKIP:
                continue
            var node = self.nodes[i].copy()
            var o = node.outputs[0]
            if k == CONV:
                vals[o] = self.conv(self.aux[i], self._get(vals, node.inputs[0]))
            elif k == ALIAS:
                vals[o] = vals.pop(node.inputs[0])
            elif k == RELU or k == SIGMOID or k == PRELU or k == BN_:
                var x = self._get(vals, node.inputs[0])
                var n = numel(x.shape)
                var y = self._out(vals, node.inputs[0], i, n)
                if k == RELU or k == SIGMOID:
                    if k == RELU:
                        self.ctx.enqueue_function[act_k[0]](fp(x.buf), fp(y), Int32(n), grid_dim=grid(n), block_dim=THREADS)
                    else:
                        self.ctx.enqueue_function[act_k[1]](fp(x.buf), fp(y), Int32(n), grid_dim=grid(n), block_dim=THREADS)
                else:
                    var a = self.aux[i]
                    var p = P(0)
                    p[0] = Int32(n)
                    p[1] = Int32(self.cn[a])
                    p[2] = Int32(numel(x.shape) // (x.shape[0] * x.shape[1]))
                    if k == PRELU:
                        self.ctx.enqueue_function[chan_k[0]](fp(x.buf), fp(self.cs[a]), fp(self.ct[a]), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                    else:
                        self.ctx.enqueue_function[chan_k[1]](fp(x.buf), fp(self.cs[a]), fp(self.ct[a]), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                vals[o] = Val(x.shape.copy(), y)
            elif k == CONSTANT:
                pass  # resident since init
            elif (k == ADD or k == MUL or k == MODI or k == DIV) and node.inputs[0] in ints:  # shape arithmetic
                var a = ints[node.inputs[0]].copy()
                var b = ints[node.inputs[1]].copy()
                var r = List[Int]()
                for q in range(max(len(a), len(b))):
                    var x = a[q if len(a) > 1 else 0]
                    var y = b[q if len(b) > 1 else 0]
                    r.append(x + y if k == ADD else (x * y if k == MUL else (x % y if k == MODI else x // y)))
                ints[o] = r^
            elif k == SHAPE and node.inputs[0] in ints:
                ints[o] = [len(ints[node.inputs[0]])]
            elif k == CAST and node.inputs[0] in ints and node.int_attr("to", 1) == 1:  # integers read as floats
                var idf = List[Float32]()
                for q in ints[node.inputs[0]]:
                    idf.append(Float32(q))
                vals[o] = Val([len(idf)], self.up(idf))
            elif k == CAST and node.inputs[0] not in ints:  # float to float: the same values
                if node.int_attr("to", 1) != 1:
                    raise Error("gpu: Cast of a float tensor to an integer type (" + node.name + ")")
                var x = self._get(vals, node.inputs[0])
                vals[o] = Val(x.shape.copy(), self._out(vals, node.inputs[0], i, numel(x.shape), copy=True))
            elif k == SQUEEZE and node.inputs[0] not in ints:  # float tensor: same values, fewer dims
                var x = self._get(vals, node.inputs[0])
                var axes = ints[node.inputs[1]].copy() if len(node.inputs) > 1 else node.ints_attr("axes")
                var shp = List[Int]()
                for q in range(len(x.shape)):
                    var hit = len(axes) == 0 and x.shape[q] == 1
                    for ax in axes:
                        if (ax if ax >= 0 else ax + len(x.shape)) == q:
                            hit = True
                    if not hit:
                        shp.append(x.shape[q])
                vals[o] = Val(shp^, self._out(vals, node.inputs[0], i, numel(x.shape), copy=True))
            elif (k == RESHAPE or k == CAST or k == SQUEEZE) and node.inputs[0] in ints:
                ints[o] = ints[node.inputs[0]].copy()
            elif k == COF:
                ref t = node.attrs[node.attr("value")].t[0]
                if len(t.f) > 0:
                    raise Error("gpu: float ConstantOfShape (" + node.name + ")")
                var n = 1
                for q in ints[node.inputs[0]]:
                    n *= q
                ints[o] = List[Int](length=n, fill=t.i[0])
            elif k == GATHER and node.inputs[0] not in ints and node.inputs[1] in vals:  # embedding lookup: ids are a device tensor (a graph input, floats)
                var x = self._get(vals, node.inputs[0])
                var ib = self._get(vals, node.inputs[1])
                var row = numel(x.shape) // x.shape[0]
                var n = numel(ib.shape) * row
                var y = self.take(n)
                self.ctx.enqueue_function[rows_k](fp(x.buf), fp(ib.buf), fp(y), Int32(n), Int32(row), grid_dim=grid(n), block_dim=THREADS)
                var shp = ib.shape.copy()
                for q in range(1, len(x.shape)):
                    shp.append(x.shape[q])
                vals[o] = Val(shp^, y)
            elif k == GATHER and node.inputs[0] not in ints:  # rows of a float table, ids on the host
                var x = self._get(vals, node.inputs[0])
                var ids = ints[node.inputs[1]].copy()
                var ax = node.attrs[node.attr("axis")].i if node.attr("axis") >= 0 else 0
                ax = ax + len(x.shape) if ax < 0 else ax
                var outer = 1  # axis > 0 (SigLIP head's hidden[:, 0]): rows of the [outer * dim, inner] view
                for q in range(ax):
                    outer *= x.shape[q]
                var dim = x.shape[ax]
                var row = numel(x.shape) // (outer * dim)
                var idf = List[Float32]()
                for b in range(outer):
                    for q in ids:
                        idf.append(Float32(b * dim + (q if q >= 0 else q + dim)))
                var ib = self.up(idf)
                var n = outer * len(ids) * row
                var y = self.take(n)
                self.ctx.enqueue_function[rows_k](fp(x.buf), fp(ib), fp(y), Int32(n), Int32(row), grid_dim=grid(n), block_dim=THREADS)
                var shp = List[Int]()
                for q in range(ax):
                    shp.append(x.shape[q])
                shp.append(len(ids))
                for q in range(ax + 1, len(x.shape)):
                    shp.append(x.shape[q])
                vals[o] = Val(shp^, y)
                self.give(ib)
            elif k == UNSQUEEZE and node.inputs[0] not in ints:
                var x = self._get(vals, node.inputs[0])
                var axes = ints[node.inputs[1]].copy() if len(node.inputs) > 1 else node.ints_attr("axes")
                var r = len(x.shape) + len(axes)
                var shp = List[Int]()
                var src = 0
                for q in range(r):
                    var hit = False
                    for ax in axes:
                        if (ax if ax >= 0 else ax + r) == q:
                            hit = True
                    if hit:
                        shp.append(1)
                    else:
                        shp.append(x.shape[src])
                        src += 1
                vals[o] = Val(shp^, self._out(vals, node.inputs[0], i, numel(x.shape), copy=True))
            elif k == SLICE and node.inputs[0] not in ints:  # float tensor, step 1: a strided gather with an offset
                var x = self._get(vals, node.inputs[0])
                var starts = ints[node.inputs[1]].copy()
                var ends = ints[node.inputs[2]].copy()
                var axes = ints[node.inputs[3]].copy() if len(node.inputs) > 3 and node.inputs[3] != "" else List[Int]()
                if len(axes) == 0:
                    for q in range(len(starts)):
                        axes.append(q)
                var lo = List[Int](length=len(x.shape), fill=0)
                var shp = x.shape.copy()
                for q in range(len(axes)):
                    var ax = axes[q] if axes[q] >= 0 else axes[q] + len(x.shape)
                    var dim = x.shape[ax]
                    var s0 = starts[q] if starts[q] >= 0 else starts[q] + dim
                    var e0 = ends[q] if ends[q] >= 0 else ends[q] + dim
                    lo[ax] = max(0, min(s0, dim))
                    shp[ax] = max(lo[ax], min(e0, dim)) - lo[ax]
                vals[o] = self._bgather(x, shp^, x.shape.copy(), lo)
            elif k == BGATHER:  # Expand (numpy broadcast) or Tile
                var x = self._get(vals, node.inputs[0])
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
                    shp.append(xs[q] * ws[q] if node.op == "Tile" else max(xs[q], ws[q]))
                vals[o] = self._bgather(x, shp^, xs^, List[Int](length=r, fill=0))
            elif k == MATMUL:
                var a = self._get(vals, node.inputs[0])
                var b = self._get(vals, node.inputs[1])
                var ra = len(a.shape)
                var rb = len(b.shape)
                var m = a.shape[ra - 2]
                var kk = a.shape[ra - 1]
                var n = b.shape[rb - 1]
                var batch = numel(a.shape) // (m * kk)
                if rb > 2 and numel(b.shape) // (kk * n) != batch:
                    raise Error("gpu: MatMul batch dims differ (" + node.name + ")")
                var shp = a.shape.copy()
                shp[ra - 1] = n
                var y = self.take(batch * m * n)
                if node.inputs[1] in self.mw16:  # fp16 arm: WMMA, A cast once per call
                    var mm = batch * m
                    self._grow16(mm * kk)
                    var hp = H(unsafe_from_address=Int(self.col16.unsafe_ptr()))
                    self.ctx.enqueue_function[half_k](fp(a.buf), hp, Int32(mm * kk), grid_dim=grid(mm * kk), block_dim=THREADS)
                    self.gemm16(self.col16, self.mw16[node.inputs[1]], y, mm, kk, n)
                elif batch == 1 or rb == 2:  # shared weight: the batch folds into M, one GEMM
                    self.gemm32(a.buf, b.buf, y, batch * m, kk, n)
                else:
                    for q in range(batch):
                        var sa = a.buf.create_sub_buffer[DType.float32](q * m * kk, m * kk)
                        var sb = b.buf.create_sub_buffer[DType.float32](q * kk * n if rb > 2 else 0, kk * n)
                        var sy = y.create_sub_buffer[DType.float32](q * m * n, m * n)
                        self.gemm32(sa, sb, sy, m, kk, n)
                vals[o] = Val(shp^, y)
            elif k == LNORM or k == SOFTMAX:
                var x = self._get(vals, node.inputs[0])
                var inner = x.shape[len(x.shape) - 1]
                var n = numel(x.shape)
                var rows = n // inner
                var y = self._out(vals, node.inputs[0], i, n)
                if k == LNORM:
                    if node.int_attr("axis", -1) != -1 and node.int_attr("axis", -1) != len(x.shape) - 1:
                        raise Error("gpu: LayerNormalization over the last axis only (" + node.name + ")")
                    var eps = node.attrs[node.attr("epsilon")].f if node.attr("epsilon") >= 0 else Float32(1e-5)
                    var g = self._get(vals, node.inputs[1])
                    var bb = self._get(vals, node.inputs[2])
                    self.ctx.enqueue_function[ln_k](fp(x.buf), fp(g.buf), fp(bb.buf), fp(y), Int32(rows), Int32(inner), eps, grid_dim=rows, block_dim=THREADS)
                else:
                    self.ctx.enqueue_function[softmax_k](fp(x.buf), fp(y), Int32(rows), Int32(inner), grid_dim=rows, block_dim=THREADS)
                vals[o] = Val(x.shape.copy(), y)
            elif k == TANH or k == EXP:
                var x = self._get(vals, node.inputs[0])
                var n = numel(x.shape)
                var y = self._out(vals, node.inputs[0], i, n)
                if k == TANH:
                    self.ctx.enqueue_function[act_k[2]](fp(x.buf), fp(y), Int32(n), grid_dim=grid(n), block_dim=THREADS)
                else:
                    self.ctx.enqueue_function[act_k[3]](fp(x.buf), fp(y), Int32(n), grid_dim=grid(n), block_dim=THREADS)
                vals[o] = Val(x.shape.copy(), y)
            elif k == L2:
                var x = self._get(vals, node.inputs[0])
                var inner = x.shape[len(x.shape) - 1]
                var rows = numel(x.shape) // inner
                var y = self.take(rows)
                self.ctx.enqueue_function[l2_k](fp(x.buf), fp(y), Int32(rows), Int32(inner), grid_dim=grid(rows), block_dim=THREADS)
                var shp = x.shape.copy()
                if node.int_attr("keepdims", 1) == 1:
                    shp[len(shp) - 1] = 1
                else:
                    _ = shp.pop()
                vals[o] = Val(shp^, y)
            elif k == ADD or k == MUL or k == DIV:
                var an = node.inputs[0]
                var bn = node.inputs[1]
                if k != DIV and (numel(self._get(vals, an).shape) < numel(self._get(vals, bn).shape) or (numel(self._get(vals, an).shape) == numel(self._get(vals, bn).shape) and len(self._get(vals, an).shape) < len(self._get(vals, bn).shape))):
                    an = node.inputs[1]
                    bn = node.inputs[0]
                elif k == DIV and numel(self._get(vals, an).shape) < numel(self._get(vals, bn).shape):
                    raise Error("gpu: Div with a divisor larger than the dividend (" + node.name + ")")
                var a = self._get(vals, an)
                var b = self._get(vals, bn)
                var n = numel(a.shape)
                var r = len(a.shape)
                if r > 4 or len(b.shape) > r:
                    raise Error("gpu: broadcast rank in " + node.name)
                var p = P(0)
                p[0] = Int32(n)
                p[1] = Int32(1 if numel(b.shape) == n else 0)
                var acc = 1
                for q in range(3, -1, -1):
                    var ad = a.shape[q - (4 - r)] if q >= 4 - r else 1
                    var bq = q - (4 - len(b.shape))
                    var bd = b.shape[bq] if bq >= 0 else 1
                    p[2 + q] = Int32(ad)
                    p[6 + q] = Int32(acc if bd != 1 else 0)
                    acc *= bd
                var y = self._out(vals, an, i, n)
                if k == ADD:
                    self.ctx.enqueue_function[bcast_k[0]](fp(a.buf), fp(b.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                elif k == MUL:
                    self.ctx.enqueue_function[bcast_k[1]](fp(a.buf), fp(b.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                else:
                    self.ctx.enqueue_function[bcast_k[2]](fp(a.buf), fp(b.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                vals[o] = Val(a.shape.copy(), y)
            elif k == MAXPOOL or k == AVGPOOL:
                vals[o] = self._pool(self._get(vals, node.inputs[0]), node, k == MAXPOOL)
            elif k == FLATTEN or k == RESHAPE:
                var x = self._get(vals, node.inputs[0])
                var want: List[Int]
                if k == FLATTEN:
                    want = [x.shape[0], numel(x.shape) // x.shape[0]]
                else:
                    want = ints[node.inputs[1]].copy()
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
                        want[neg] = numel(x.shape) // known
                vals[o] = Val(want^, self._out(vals, node.inputs[0], i, numel(x.shape), copy=True))
            elif k == GEMM:
                var x = self._get(vals, node.inputs[0])
                var a = self.aux[i]
                var nb = x.shape[0]
                var kin = numel(x.shape) // nb
                var nout = self.fcn[a]
                var y = self.take(nb * nout)
                self.gemm32(x.buf, self.fcw[a], y, nb, kin, nout)
                if len(node.inputs) > 2:
                    var p = P(0)
                    p[0] = Int32(nb * nout)
                    p[2] = 1
                    p[3] = 1
                    p[4] = Int32(nb)
                    p[5] = Int32(nout)
                    p[9] = 1
                    self.ctx.enqueue_function[bcast_k[0]](fp(y), fp(self.res[node.inputs[2]].buf), fp(y), p, grid_dim=grid(nb * nout), block_dim=THREADS)
                vals[o] = Val([nb, nout], y)
            elif k == SHAPE:
                ints[o] = self._get(vals, node.inputs[0]).shape.copy()
            elif k == GATHER:
                var src = ints[node.inputs[0]].copy()
                var r = List[Int]()
                for q in ints[node.inputs[1]]:
                    r.append(src[q if q >= 0 else q + len(src)])
                ints[o] = r^
            elif k == UNSQUEEZE:
                ints[o] = ints[node.inputs[0]].copy()
            elif k == SLICE:
                var src = ints[node.inputs[0]].copy()
                var st = ints[node.inputs[1]][0]
                var en = ints[node.inputs[2]][0]
                st = max(0, st + len(src) if st < 0 else st)  # negative indices count from the end, as in nn.mojo
                en = min(len(src), en + len(src) if en < 0 else en)
                var r = List[Int]()
                for q in range(st, en):
                    r.append(src[q])
                ints[o] = r^
            elif k == CONCAT:
                var r = List[Int]()
                for name in node.inputs:
                    if name not in ints:
                        raise Error("gpu: Concat of tensors not supported (" + node.name + ")")
                    r.extend(ints[name].copy())
                ints[o] = r^
            elif k == RESIZE:
                var x = self._get(vals, node.inputs[0])
                var sz = ints[node.inputs[3]].copy()
                var n = sz[0] * sz[1] * sz[2] * sz[3]
                var y = self.take(n)
                var p = P(0)
                p[0] = Int32(n)
                p[1] = Int32(x.shape[2])
                p[2] = Int32(x.shape[3])
                p[3] = Int32(sz[2])
                p[4] = Int32(sz[3])
                self.ctx.enqueue_function[resize_k](fp(x.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
                vals[o] = Val(sz^, y)
            elif k == TRANSPOSE:
                vals[o] = self._transpose(self._get(vals, node.inputs[0]), node.ints_attr("perm"))
            # release values whose last consumer was this node
            for name in node.inputs:
                if self.last.get(name, -1) == i and name in vals and name not in self.outputs:
                    self.give(vals.pop(name).buf)
        self.pend = List[Arr]()
        self.pend_vals = List[Val]()
        for name in self.outputs:
            var v = vals.pop(name)
            self.pend.append(Arr(v.shape.copy()))
            self.ctx.enqueue_copy(dst_ptr=self.pend[len(self.pend) - 1].d.unsafe_ptr(), src_buf=v.buf)
            self.pend_vals.append(v^)
        for e in vals.items():  # inputs no node reads, if any
            self.give(e.value.buf)

    def collect(mut self) raises -> Dict[String, Arr]:
        self.ctx.synchronize()
        var r = Dict[String, Arr]()
        for k in range(len(self.outputs)):
            r[self.outputs[k]] = self.pend[k].copy()
            var b = self.pend_vals[k].buf
            self.give(b)
        self.pend = List[Arr]()
        self.pend_vals = List[Val]()
        self.hold = Dict[String, Arr]()
        return r^

    def run(mut self, var feeds: Dict[String, Arr]) raises -> Dict[String, Arr]:
        self.submit(feeds^)
        return self.collect()

    def _get(self, vals: Dict[String, Val], name: String) raises -> Val:
        if name in vals:
            return vals[name].copy()
        if name in self.res:
            return self.res[name].copy()
        raise Error("gpu: value not computed: " + name)

    def _out(mut self, mut vals: Dict[String, Val], src: String, i: Int, n: Int, copy: Bool = False) raises -> B32:
        """An output buffer of n floats: src's own buffer when src dies at node i (elementwise ops run in
        place), else a pool buffer; with copy, src's data copied into it."""
        if self.last.get(src, -1) == i and src in vals and src not in self.outputs and numel(vals[src].shape) == n:
            return vals.pop(src).buf
        var y = self.take(n)
        if copy:
            self.ctx.enqueue_copy(dst_buf=y, src_buf=self._get(vals, src).buf)
        return y

    def _pool(mut self, x: Val, node: Node, is_max: Bool) raises -> Val:
        var nb = x.shape[0]
        var c = x.shape[1]
        var h = x.shape[2]
        var wd = x.shape[3]
        var ks = node.ints_attr("kernel_shape")
        var st = node.ints_attr("strides")
        var pd = node.ints_attr("pads")
        var sh = st[0] if len(st) > 0 else 1
        var sw = st[1] if len(st) > 1 else sh
        var pt = pd[0] if len(pd) > 0 else 0
        var pl = pd[1] if len(pd) > 1 else 0
        var pb = pd[2] if len(pd) > 2 else pt
        var pr = pd[3] if len(pd) > 3 else pl
        var ceil = node.int_attr("ceil_mode", 0)
        var ho = (h + pt + pb - ks[0] + (sh - 1 if ceil else 0)) // sh + 1
        var wo = (wd + pl + pr - ks[1] + (sw - 1 if ceil else 0)) // sw + 1
        var n = nb * c * ho * wo
        var y = self.take(n)
        var p = P(0)
        p[0] = Int32(n)
        p[1] = Int32(h)
        p[2] = Int32(wd)
        p[3] = Int32(ks[0])
        p[4] = Int32(ks[1])
        p[5] = Int32(sh)
        p[6] = Int32(sw)
        p[7] = Int32(pt)
        p[8] = Int32(pl)
        p[9] = Int32(pb)
        p[10] = Int32(pr)
        p[11] = Int32(ho)
        p[12] = Int32(wo)
        p[13] = Int32(node.int_attr("count_include_pad", 0))
        if is_max:
            self.ctx.enqueue_function[pool_k[True]](fp(x.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
        else:
            self.ctx.enqueue_function[pool_k[False]](fp(x.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
        return Val([nb, c, ho, wo], y)

    def _bgather(mut self, x: Val, var shp: List[Int], var srcdims: List[Int], lo: List[Int]) raises -> Val:
        """out[c] = x[off + sum (c_k % src_k) * stride_k] over rank-4 views (shorter shapes padded with leading 1s)."""
        var r = len(shp)
        if r > 4:
            raise Error("gpu: Slice/Expand/Tile rank above 4")
        var xs = List[Int](length=4, fill=1)  # x dims right-aligned like shp
        for q in range(len(x.shape)):
            xs[4 - len(x.shape) + q] = x.shape[q]
        var st = List[Int](length=4, fill=0)
        var acc = 1
        for q in range(3, -1, -1):
            st[q] = acc if xs[q] != 1 else 0
            acc *= xs[q]
        var off = 0
        for q in range(len(lo)):
            off += lo[q] * st[4 - len(lo) + q]
        var p = P(0)
        var n = numel(shp)
        p[0] = Int32(n)
        for q in range(4):
            var oq = q - (4 - r)
            p[1 + q] = Int32(shp[oq] if oq >= 0 else 1)
            var sq = q - (4 - len(srcdims))
            p[5 + q] = Int32(srcdims[sq] if sq >= 0 else 1)
            p[9 + q] = Int32(st[q])
        p[13] = Int32(off)
        var y = self.take(n)
        self.ctx.enqueue_function[bgather_k](fp(x.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
        return Val(shp^, y)

    def _transpose(mut self, x: Val, perm: List[Int]) raises -> Val:
        var r = len(x.shape)
        if r > 4:  # size-1 dims move nothing: transpose the others, then restore the full output shape
            var newi = List[Int](length=r, fill=-1)
            var rs = List[Int]()
            for q in range(r):
                if x.shape[q] != 1:
                    newi[q] = len(rs)
                    rs.append(x.shape[q])
            if len(rs) > 4:
                raise Error("gpu: transpose rank > 4 with more than 4 dims above 1")
            var rperm = List[Int]()
            for q in perm:
                if newi[q] >= 0:
                    rperm.append(newi[q])
            var inner = self._transpose(Val(rs^, x.buf), rperm)
            var full = List[Int]()
            for q in perm:
                full.append(x.shape[q])
            return Val(full^, inner.buf)
        var pad = 4 - r
        var xs = List[Int](length=4, fill=1)
        for q in range(r):
            xs[pad + q] = x.shape[q]
        var pm = List[Int]()
        for q in range(pad):
            pm.append(q)
        for q in perm:
            pm.append(q + pad)
        var ist = List[Int](length=4, fill=1)
        for q in range(2, -1, -1):
            ist[q] = ist[q + 1] * xs[q + 1]
        var n = numel(x.shape)
        var p = P(0)
        p[0] = Int32(n)
        var shp = List[Int]()
        for q in range(4):
            p[1 + q] = Int32(xs[pm[q]])
            p[5 + q] = Int32(ist[pm[q]])
        for q in perm:
            shp.append(x.shape[q])
        var y = self.take(n)
        self.ctx.enqueue_function[transpose_k](fp(x.buf), fp(y), p, grid_dim=grid(n), block_dim=THREADS)
        return Val(shp^, y)
