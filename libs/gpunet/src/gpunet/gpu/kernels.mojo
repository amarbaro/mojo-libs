# Device kernels for the GPU runner besides GEMM: im2col, conv epilogue, activations, per-channel ops,
# broadcast Add/Mul, pools, nearest Resize, Transpose. NCHW float32, one thread per output element,
# 32-bit index math. Shape parameters travel in one Int32x16 vector `p`.
from std.math import ceildiv, exp, sqrt, tanh
from max.gpu import global_idx, block_idx, thread_idx, lane_id, WARP_SIZE
from max.gpu.sync import barrier
from max.gpu.primitives import warp
from max.gpu.memory import AddressSpace
from std.memory import stack_allocation

comptime F = MutPointer[Float32, MutUntrackedOrigin]
comptime P = SIMD[DType.int32, 16]
comptime THREADS = 256


def grid(n: Int) -> Int:
    return ceildiv(n, THREADS)


def im2col_k[T: DType](x: F, col: MutPointer[Scalar[T], MutUntrackedOrigin], p: P):
    """col[r, j] of a [kp, np] matrix: r = (channel, ky, kx) tap, j = image * HW + pixel; zero outside.
    p: cin h w kh kw sh sw pt pl dh dw ho wo kp np nb."""
    var e = Int32(global_idx.x)
    var np_ = p[14]
    if e >= p[13] * np_:
        return
    var r = e // np_
    var j = e % np_
    var cin = p[0]
    var h = p[1]
    var w = p[2]
    var kh = p[3]
    var kw = p[4]
    var hw = p[11] * p[12]
    var v = Float32(0)
    if r < cin * kh * kw and j < p[15] * hw:
        var c = r // (kh * kw)
        var b = j // hw
        var px = j % hw
        var iy = (px // p[12]) * p[5] - p[7] + ((r // kw) % kh) * p[9]
        var ix = (px % p[12]) * p[6] - p[8] + (r % kw) * p[10]
        if iy >= 0 and iy < h and ix >= 0 and ix < w:
            v = x[unsafe_offset=Int(((b * cin + c) * h + iy) * w + ix)]
    col[unsafe_offset=Int(e)] = v.cast[T]()


def half_k(x: F, y: MutPointer[Float16, MutUntrackedOrigin], n: Int32):
    """y = fp16(x), the A operand of a linear layer on the WMMA arm."""
    var e = Int32(global_idx.x)
    if e < n:
        y[unsafe_offset=Int(e)] = x[unsafe_offset=Int(e)].cast[DType.float16]()


def epilogue_k(c: F, bias: F, y: F, p: P):
    """y[b, o, q] = act(c[o, b * hw + q] + bias[o]); c may be y when nb == 1 and np == hw.
    p: cout nb hw np relu."""
    var e = Int32(global_idx.x)
    var cout = p[0]
    var hw = p[2]
    if e >= p[1] * cout * hw:
        return
    var b = e // (cout * hw)
    var o = (e // hw) % cout
    var v = c[unsafe_offset=Int(o * p[3] + b * hw + e % hw)] + bias[unsafe_offset=Int(o)]
    if p[4] != 0:
        v = max(v, 0.0)
    y[unsafe_offset=Int(e)] = v


def act_k[op: Int](x: F, y: F, n: Int32):
    """op 0 Relu, 1 Sigmoid, 2 Tanh, 3 Exp."""
    var e = Int32(global_idx.x)
    if e >= n:
        return
    var v = x[unsafe_offset=Int(e)]
    comptime if op == 0:
        y[unsafe_offset=Int(e)] = max(v, 0.0)
    elif op == 1:
        y[unsafe_offset=Int(e)] = 1.0 / (1.0 + exp(-v))
    elif op == 2:
        y[unsafe_offset=Int(e)] = tanh(v)
    else:
        y[unsafe_offset=Int(e)] = exp(v)


def chan_k[op: Int](x: F, s: F, t: F, y: F, p: P):
    """Per-channel op over NCHW; op 0 PRelu (slope s), 1 folded BatchNorm (x * s + t). p: n C HW."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var c = Int((e // p[2]) % p[1])
    var v = x[unsafe_offset=Int(e)]
    comptime if op == 0:
        y[unsafe_offset=Int(e)] = v * s[unsafe_offset=c] if v < 0 else v
    else:
        y[unsafe_offset=Int(e)] = v * s[unsafe_offset=c] + t[unsafe_offset=c]


def bcast_k[op: Int](a: F, b: F, y: F, p: P):
    """y = a + b (op 0), a * b (op 1) or a / b (op 2); b broadcast onto a's rank-4 shape.
    p: n same d0 d1 d2 d3 s0 s1 s2 s3 (d = a dims, s = b strides, 0 on broadcast dims)."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var bi = e
    if p[1] == 0:
        var rem = e
        bi = (rem % p[5]) * p[9]
        rem //= p[5]
        bi += (rem % p[4]) * p[8]
        rem //= p[4]
        bi += (rem % p[3]) * p[7] + (rem // p[3]) * p[6]
    comptime if op == 0:
        y[unsafe_offset=Int(e)] = a[unsafe_offset=Int(e)] + b[unsafe_offset=Int(bi)]
    elif op == 1:
        y[unsafe_offset=Int(e)] = a[unsafe_offset=Int(e)] * b[unsafe_offset=Int(bi)]
    else:
        y[unsafe_offset=Int(e)] = a[unsafe_offset=Int(e)] / b[unsafe_offset=Int(bi)]


def pool_k[is_max: Bool](x: F, y: F, p: P):
    """MaxPool / AveragePool as nn.pool. p: n h w kh kw sh sw pt pl pb pr ho wo incl."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var h = p[1]
    var w = p[2]
    var ho = p[11]
    var wo = p[12]
    var ch = e // (ho * wo)
    var oy = (e // wo) % ho
    var ox = e % wo
    var best = Float32(-3.4e38)
    var s = Float32(0)
    var cnt = Int32(0)
    var i = Int32(0)
    while i < p[3]:
        var iy = oy * p[5] - p[7] + i
        var j = Int32(0)
        while j < p[4]:
            var ix = ox * p[6] - p[8] + j
            if iy >= 0 and iy < h and ix >= 0 and ix < w:
                var v = x[unsafe_offset=Int((ch * h + iy) * w + ix)]
                best = max(best, v)
                s += v
                cnt += 1
            elif iy < h + p[9] and ix < w + p[10]:
                cnt += p[13]
            j += 1
        i += 1
    comptime if is_max:
        y[unsafe_offset=Int(e)] = best
    else:
        y[unsafe_offset=Int(e)] = s / Float32(max(cnt, 1))


def resize_k(x: F, y: F, p: P):
    """Nearest, asymmetric, floor. p: n h w ho wo."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var h = p[1]
    var w = p[2]
    var ho = p[3]
    var wo = p[4]
    var ch = e // (ho * wo)
    var iy = min(h - 1, ((e // wo) % ho) * h // ho)
    var ix = min(w - 1, (e % wo) * w // wo)
    y[unsafe_offset=Int(e)] = x[unsafe_offset=Int((ch * h + iy) * w + ix)]


def transpose_k(x: F, y: F, p: P):
    """Rank-4 transpose. p: n d0 d1 d2 d3 s0 s1 s2 s3 (d = out dims, s = input strides in out order)."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var rem = e
    var src = Int32(0)
    comptime for k in range(3, -1, -1):
        src += (rem % p[1 + k]) * p[5 + k]
        rem //= p[1 + k]
    y[unsafe_offset=Int(e)] = x[unsafe_offset=Int(src)]


def _bsum(v: Float32, sh: MutPointer[Float32, MutUntrackedOrigin, address_space=AddressSpace.SHARED]) -> Float32:
    """Sum over the 256-thread block (8 waves of 32), every thread gets the total."""
    var w = warp.sum(v)
    if lane_id() == 0:
        sh[unsafe_offset=Int(thread_idx.x // WARP_SIZE)] = w
    barrier()
    var t = Float32(0)
    comptime for k in range(THREADS // 32):
        t += sh[unsafe_offset=k]
    barrier()
    return t


def _bmax(v: Float32, sh: MutPointer[Float32, MutUntrackedOrigin, address_space=AddressSpace.SHARED]) -> Float32:
    var w = warp.max(v)
    if lane_id() == 0:
        sh[unsafe_offset=Int(thread_idx.x // WARP_SIZE)] = w
    barrier()
    var t = sh[unsafe_offset=0]
    comptime for k in range(1, THREADS // 32):
        t = max(t, sh[unsafe_offset=k])
    barrier()
    return t


def ln_k(x: F, g: F, b: F, y: F, rows: Int32, inner: Int32, eps: Float32):
    """LayerNormalization over the last axis, one 256-thread block per row (x and y may be the same buffer)."""
    var sh = stack_allocation[THREADS // 32, Float32, address_space=AddressSpace.SHARED]()
    var base = Int(block_idx.x) * Int(inner)
    var t = Int(thread_idx.x)
    var s = Float32(0)
    for j in range(t, Int(inner), THREADS):
        s += x[unsafe_offset=base + j]
    var mu = _bsum(s, sh) / Float32(inner)
    var vs = Float32(0)
    for j in range(t, Int(inner), THREADS):
        var d = x[unsafe_offset=base + j] - mu
        vs += d * d
    var inv = 1.0 / sqrt(_bsum(vs, sh) / Float32(inner) + eps)
    for j in range(t, Int(inner), THREADS):
        y[unsafe_offset=base + j] = (x[unsafe_offset=base + j] - mu) * inv * g[unsafe_offset=j] + b[unsafe_offset=j]


def softmax_k(x: F, y: F, rows: Int32, n: Int32):
    """Softmax over the last axis, one 256-thread block per row (in place allowed)."""
    var sh = stack_allocation[THREADS // 32, Float32, address_space=AddressSpace.SHARED]()
    var base = Int(block_idx.x) * Int(n)
    var t = Int(thread_idx.x)
    var mx = Float32.MIN
    for j in range(t, Int(n), THREADS):
        mx = max(mx, x[unsafe_offset=base + j])
    mx = _bmax(mx, sh)
    var s = Float32(0)
    for j in range(t, Int(n), THREADS):
        s += exp(x[unsafe_offset=base + j] - mx)
    var inv = 1.0 / _bsum(s, sh)
    for j in range(t, Int(n), THREADS):
        y[unsafe_offset=base + j] = exp(x[unsafe_offset=base + j] - mx) * inv


def l2_k(x: F, y: F, rows: Int32, n: Int32):
    """ReduceL2 over the last axis: y[row] = sqrt(sum x^2)."""
    var r = Int32(global_idx.x)
    if r >= rows:
        return
    var s = Float32(0)
    for j in range(Int(n)):
        var v = x[unsafe_offset=Int(r * n) + j]
        s += v * v
    y[unsafe_offset=Int(r)] = sqrt(s)


def rows_k(tab: F, ids: F, y: F, n: Int32, row: Int32):
    """Gather rows of a float table; ids are float32 holding integers (exact below 2^24)."""
    var e = Int32(global_idx.x)
    if e >= n:
        return
    y[unsafe_offset=Int(e)] = tab[unsafe_offset=Int(Int32(ids[unsafe_offset=Int(e // row)]) * row + e % row)]


def bgather_k(x: F, y: F, p: P):
    """Slice (step 1), Expand and Tile of a rank-4 tensor: out[c] = x[off + sum (c_k % src_k) * s_k].
    p: n d0 d1 d2 d3 (out dims) x0 x1 x2 x3 (source dims) s0 s1 s2 s3 (source strides) off."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var rem = e
    var src = p[13]
    comptime for k in range(3, -1, -1):
        src += ((rem % p[1 + k]) % p[5 + k]) * p[9 + k]
        rem //= p[1 + k]
    y[unsafe_offset=Int(e)] = x[unsafe_offset=Int(src)]
