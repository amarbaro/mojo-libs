# gpu: MAX GPU twins of the per-image ops the stock job runs: BGR/RGB to grey, integer area shrink, sharpness
# (Laplacian variance, Tenengrad, soft tiles), Sobel 3x3 and a crop. Every kernel is integer arithmetic in the same order as
# its CPU op, so the output is the CPU output byte for byte and the oracle rows (cv2 5.0) hold for both: tests/cases_gpu/gpu.txt
# runs the CPU rows again with gpu=1. `mojo-cv OP OUT IN... gpu=1` takes the GPU for the ops below; a parameter the kernel does
# not cover, or no accelerator, leaves the CPU path in charge (it is the default and the fallback). Timings include the
# upload and the download: that is the op as a caller meets it (docs/gpu.md).
# fs-gpu2 (R3a, R3b): absdiff (uint8 and float32) and bilinear resize (uint8 ch 1, 3, 4: cv2's 11-bit fixed point, byte for byte;
# float32 ch 1, 3, 4: the CPU's tap order, measured tolerance). A GPU run prints `GPU-ARM OP ...` so a receipt shows the arm ran.
# The stream ops (stream.mojo) are dispatched from run() below: main.mojo has one owner, this file another.
from std.math import ceildiv
from max.gpu import global_idx
from max.gpu.host import DeviceContext, DeviceBuffer
from mojocv.mat import Mat, load, save
from mojocv.core import Args, peek_code
from mojocv.imgproc import cvt_code, Taps, _fx_taps
from mojocv.stream import run as run_stream
from mojocv.hyper import evm_blur

comptime U8 = DType.uint8
comptime U = MutPointer[UInt8, MutUntrackedOrigin]
comptime S = MutPointer[Int16, MutUntrackedOrigin]
comptime L = MutPointer[Int64, MutUntrackedOrigin]
comptime F = MutPointer[Float32, MutUntrackedOrigin]
comptime I = MutPointer[Int32, MutUntrackedOrigin]
comptime D = MutPointer[Float64, MutUntrackedOrigin]
comptime P = SIMD[DType.int32, 8]
comptime THREADS = 256


def gray_k(src: U, dst: U, n: Int32, rgb: Int32):
    """cv2 5.0's integer grey: (B 3735 + G 19235 + R 9798 + 16384) >> 15; rgb = 1 reads the pixels as R, G, B."""
    var e = Int32(global_idx.x)
    if e < n:
        var i = Int(e) * 3
        var c0 = Int32(src[unsafe_offset=i])
        var g = Int32(src[unsafe_offset=i + 1])
        var c2 = Int32(src[unsafe_offset=i + 2])
        var b = c0 if rgb == 0 else c2
        var r = c2 if rgb == 0 else c0
        dst[unsafe_offset=Int(e)] = UInt8((b * 3735 + g * 19235 + r * 9798 + 16384) >> 15)


def boxdown_k(src: U, dst: U, p: P):
    """Each output sample is the rounded mean of an f x f block. p: rows cols ch f R C."""
    var e = Int32(global_idx.x)
    var ch = p[2]
    var f = p[3]
    var oc = p[5]
    if e >= p[4] * oc * ch:
        return
    var k = e % ch
    var x = (e // ch) % oc
    var y = e // (ch * oc)
    var s = Int32(0)
    for dy in range(Int(f)):
        for dx in range(Int(f)):
            s += Int32(src[unsafe_offset=Int(((y * f + Int32(dy)) * p[1] + x * f + Int32(dx)) * ch + k)])
    dst[unsafe_offset=Int(e)] = UInt8((s + (f * f) // 2) // (f * f))


def sharp_k(src: U, res: L, p: P):
    """One thread per (interior row, column segment of `tile` pixels, plus the remainder): sums of the 4-neighbour Laplacian,
    its square, and Sobel gx^2 + gy^2 over the segment. p: rows cols tile tx."""
    var e = Int32(global_idx.x)
    var rows = p[0]
    var cols = p[1]
    var tile = p[2]
    var tx = p[3]
    if e >= (rows - 2) * (tx + 1):
        return
    var y = 1 + e // (tx + 1)
    var seg = e % (tx + 1)
    var xa = 1 + seg * tile
    var xb = xa + tile if seg < tx else cols - 1
    var s1 = Int64(0)
    var s2 = Int64(0)
    var tg = Int64(0)
    for x in range(Int(xa), Int(xb)):
        var o0 = Int((y - 1) * cols) + x
        var o1 = o0 + Int(cols)
        var o2 = o1 + Int(cols)
        var a00 = Int64(src[unsafe_offset=o0 - 1])
        var a01 = Int64(src[unsafe_offset=o0])
        var a02 = Int64(src[unsafe_offset=o0 + 1])
        var a10 = Int64(src[unsafe_offset=o1 - 1])
        var a11 = Int64(src[unsafe_offset=o1])
        var a12 = Int64(src[unsafe_offset=o1 + 1])
        var a20 = Int64(src[unsafe_offset=o2 - 1])
        var a21 = Int64(src[unsafe_offset=o2])
        var a22 = Int64(src[unsafe_offset=o2 + 1])
        var l = a01 + a21 + a10 + a12 - 4 * a11
        var gx = a02 + 2 * a12 + a22 - a00 - 2 * a10 - a20
        var gy = a20 + 2 * a21 + a22 - a00 - 2 * a01 - a02
        s1 += l
        s2 += l * l
        tg += gx * gx + gy * gy
    res[unsafe_offset=Int(e) * 3] = s1
    res[unsafe_offset=Int(e) * 3 + 1] = s2
    res[unsafe_offset=Int(e) * 3 + 2] = tg


def _refl(i: Int32, n: Int32) -> Int32:
    return -i if i < 0 else (2 * n - 2 - i if i >= n else i)


def sobel3_k(src: U, dst: S, p: P):
    """Sobel 3 x 3, scale 1, border reflect-101, uint8 in, int16 out. p: rows cols dx dy (dx = 1: d/dx, else d/dy)."""
    var e = Int32(global_idx.x)
    var rows = p[0]
    var cols = p[1]
    if e >= rows * cols:
        return
    var y = e // cols
    var x = e % cols
    var s = Int32(0)
    for t in range(-1, 2):
        var w = Int32(2 if t == 0 else 1)
        if p[2] == 1:
            var yy = _refl(y + Int32(t), rows)
            s += w * (Int32(src[unsafe_offset=Int(yy * cols + _refl(x + 1, cols))]) - Int32(src[unsafe_offset=Int(yy * cols + _refl(x - 1, cols))]))
        else:
            var xx = _refl(x + Int32(t), cols)
            s += w * (Int32(src[unsafe_offset=Int(_refl(y + 1, rows) * cols + xx)]) - Int32(src[unsafe_offset=Int(_refl(y - 1, rows) * cols + xx)]))
    dst[unsafe_offset=Int(e)] = Int16(s)


def crop_k(src: U, dst: U, p: P):
    """Copy the w x h window at (x0, y0). p: rows cols ch x0 y0 w h."""
    var e = Int32(global_idx.x)
    var ch = p[2]
    if e >= p[5] * p[6] * ch:
        return
    var k = e % ch
    var x = (e // ch) % p[5]
    var y = e // (ch * p[5])
    dst[unsafe_offset=Int(e)] = src[unsafe_offset=Int(((p[4] + y) * p[1] + p[3] + x) * ch + k)]


def absdiff_u8_k(a: U, b: U, dst: U, n: Int32):
    """|a - b| per byte (the CPU's max - min)."""
    var e = Int32(global_idx.x)
    if e < n:
        var x = Int32(a[unsafe_offset=Int(e)])
        var y = Int32(b[unsafe_offset=Int(e)])
        dst[unsafe_offset=Int(e)] = UInt8(x - y if x > y else y - x)


def absdiff_f32_k(a: F, b: F, dst: F, n: Int32):
    """max - min per float32, the CPU's formula."""
    var e = Int32(global_idx.x)
    if e < n:
        var x = a[unsafe_offset=Int(e)]
        var y = b[unsafe_offset=Int(e)]
        dst[unsafe_offset=Int(e)] = max(x, y) - min(x, y)


def resize_u8_k(src: U, dst: U, tx: I, ty: I, p: P):
    """cv2's uint8 INTER_LINEAR, 11-bit weights: horizontal two-tap sum (exact in int32), then ((b0 * (h0 >> 4)) >> 16 +
    (b1 * (h1 >> 4)) >> 16 + 2) >> 2, the CPU's _resize_lin_u8 per output sample. tx, ty: i0, i1, w0, w1 per output column or row.
    p: rows cols ch dh dw."""
    var e = Int32(global_idx.x)
    var ch = p[2]
    var dw = p[4]
    if e >= p[3] * dw * ch:
        return
    var k = e % ch
    var x = (e // ch) % dw
    var y = e // (ch * dw)
    var r0 = Int(tx[unsafe_offset=Int(x) * 4])
    var r1 = Int(tx[unsafe_offset=Int(x) * 4 + 1])
    var a0 = tx[unsafe_offset=Int(x) * 4 + 2]
    var a1 = tx[unsafe_offset=Int(x) * 4 + 3]
    var ya = Int(ty[unsafe_offset=Int(y) * 4])
    var yb = Int(ty[unsafe_offset=Int(y) * 4 + 1])
    var b0 = ty[unsafe_offset=Int(y) * 4 + 2]
    var b1 = ty[unsafe_offset=Int(y) * 4 + 3]
    var sn = Int(p[1] * ch)
    var c = Int(k)
    var h0 = a0 * Int32(src[unsafe_offset=ya * sn + r0 * Int(ch) + c]) + a1 * Int32(src[unsafe_offset=ya * sn + r1 * Int(ch) + c])
    var h1 = a0 * Int32(src[unsafe_offset=yb * sn + r0 * Int(ch) + c]) + a1 * Int32(src[unsafe_offset=yb * sn + r1 * Int(ch) + c])
    var v = (((b0 * (h0 >> 4)) >> 16) + ((b1 * (h1 >> 4)) >> 16) + 2) >> 2
    dst[unsafe_offset=Int(e)] = UInt8(min(max(v, 0), 255))


def resize_f32_k(src: F, dst: F, txi: I, txw: F, tyi: I, tyw: F, p: P):
    """The CPU's float path for linear taps: rows first (two taps, in order), then columns. p: rows cols ch dh dw."""
    var e = Int32(global_idx.x)
    var ch = p[2]
    var dw = p[4]
    if e >= p[3] * dw * ch:
        return
    var k = Int(e % ch)
    var x = Int((e // ch) % dw)
    var y = Int(e // (ch * dw))
    var sn = Int(p[1] * ch)
    var res = Float32(0)
    for qx in range(2):
        var cx = Int(txi[unsafe_offset=x * 2 + qx])
        var v = Float32(0)
        for qy in range(2):
            v += src[unsafe_offset=Int(tyi[unsafe_offset=y * 2 + qy]) * sn + cx * Int(ch) + k] * tyw[unsafe_offset=y * 2 + qy]
        res += v * txw[unsafe_offset=x * 2 + qx]
    dst[unsafe_offset=Int(e)] = res


def evm_k(orig: F, sm: F, o: F, st: D, p: P, alpha: Float64, lo: Float64, hi: Float64):
    """hyper.evm_run, one thread per pixel: the two IIR low-passes over the pixel's T frames in float64, in the CPU's order.
    p: pixels T init (1: both start on the first frame of sm; 0: continue from st). st holds L_hi, L_lo per pixel and is left at the last frame."""
    var e = Int32(global_idx.x)
    if e >= p[0]:
        return
    var t_n = Int(p[1])
    var b = Int(e) * t_n
    var l1 = Float64(sm[unsafe_offset=b]) if p[2] == 1 else st[unsafe_offset=2 * Int(e)]
    var l2 = l1 if p[2] == 1 else st[unsafe_offset=2 * Int(e) + 1]
    for t in range(t_n):
        var s = Float64(sm[unsafe_offset=b + t])
        l1 += hi * (s - l1)
        l2 += lo * (s - l2)
        o[unsafe_offset=b + t] = Float32(Float64(orig[unsafe_offset=b + t]) + alpha * (l1 - l2))
    st[unsafe_offset=2 * Int(e)] = l1
    st[unsafe_offset=2 * Int(e) + 1] = l2


def _u(b: DeviceBuffer[DType.uint8]) -> U:
    return U(unsafe_from_address=Int(b.unsafe_ptr()))


struct Gpu:
    var ctx: DeviceContext

    def __init__(out self) raises:
        self.ctx = DeviceContext()  # raises when there is no accelerator

    def _up(self, m: Mat[U8]) raises -> DeviceBuffer[DType.uint8]:
        var b = self.ctx.enqueue_create_buffer[DType.uint8](m.size())
        self.ctx.enqueue_copy(dst_buf=b, src_ptr=m.data.unsafe_ptr())
        return b^

    def _down(self, mut m: Mat[U8], b: DeviceBuffer[DType.uint8]) raises:
        self.ctx.enqueue_copy(dst_ptr=m.data.unsafe_ptr(), src_buf=b)
        self.ctx.synchronize()

    def gray(self, src: Mat[U8], rgb: Bool) raises -> Mat[U8]:
        var n = src.rows * src.cols
        var a = self._up(src)
        var b = self.ctx.enqueue_create_buffer[DType.uint8](n)
        self.ctx.enqueue_function[gray_k](_u(a), _u(b), Int32(n), Int32(1 if rgb else 0), grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[U8](src.rows, src.cols, 1, False)
        self._down(o, b)
        return o^

    def box_down(self, src: Mat[U8], f: Int) raises -> Mat[U8]:
        var R = src.rows // f
        var C = src.cols // f
        var n = R * C * src.ch
        var a = self._up(src)
        var b = self.ctx.enqueue_create_buffer[DType.uint8](n)
        var p = P(Int32(src.rows), Int32(src.cols), Int32(src.ch), Int32(f), Int32(R), Int32(C), 0, 0)
        self.ctx.enqueue_function[boxdown_k](_u(a), _u(b), p, grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[U8](R, C, src.ch, False)
        self._down(o, b)
        return o^

    def sharpness(self, g: Mat[U8], tile: Int, thr: Float64) raises -> Mat[DType.float64]:
        """The 1 x 3 of stockcheck.sharpness: Laplacian variance, Tenengrad, share of soft tiles."""
        var R = g.rows
        var C = g.cols
        var ty = (R - 2) // tile
        var tx = (C - 2) // tile
        var nt = (R - 2) * (tx + 1)
        var a = self._up(g)
        var ob = self.ctx.enqueue_create_buffer[DType.int64](nt * 3)
        var p = P(Int32(R), Int32(C), Int32(tile), Int32(tx), 0, 0, 0, 0)
        self.ctx.enqueue_function[sharp_k](_u(a), L(unsafe_from_address=Int(ob.unsafe_ptr())), p, grid_dim=ceildiv(nt, THREADS), block_dim=THREADS)
        var h = List[Int64](length=nt * 3, fill=0)
        self.ctx.enqueue_copy(dst_ptr=h.unsafe_ptr(), src_buf=ob)
        self.ctx.synchronize()
        var ts1 = List[Int64](length=ty * tx, fill=0)
        var ts2 = List[Int64](length=ty * tx, fill=0)
        var s1: Int64 = 0
        var s2: Int64 = 0
        var tg: Int64 = 0
        for e in range(nt):
            var y = 1 + e // (tx + 1)
            var seg = e % (tx + 1)
            s1 += h[3 * e]
            s2 += h[3 * e + 1]
            tg += h[3 * e + 2]
            var tyi = (y - 1) // tile
            if seg < tx and tyi < ty:
                ts1[tyi * tx + seg] += h[3 * e]
                ts2[tyi * tx + seg] += h[3 * e + 1]
        var n = Float64((R - 2) * (C - 2))
        var mean = Float64(s1) / n
        var tn = Int64(tile * tile)
        var soft = 0
        for i in range(ty * tx):
            if Float64(tn * ts2[i] - ts1[i] * ts1[i]) / Float64(tn * tn) < thr:
                soft += 1
        var o = Mat[DType.float64](1, 3, 1)
        o.data[0] = Float64(s2) / n - mean * mean
        o.data[1] = Float64(tg) / n
        o.data[2] = Float64(soft) / Float64(ty * tx)
        return o^

    def sobel3(self, g: Mat[U8], dx: Int) raises -> Mat[DType.int16]:
        var n = g.rows * g.cols
        var a = self._up(g)
        var ob = self.ctx.enqueue_create_buffer[DType.int16](n)
        var p = P(Int32(g.rows), Int32(g.cols), Int32(dx), Int32(1 - dx), 0, 0, 0, 0)
        self.ctx.enqueue_function[sobel3_k](_u(a), S(unsafe_from_address=Int(ob.unsafe_ptr())), p, grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[DType.int16](g.rows, g.cols, 1, False)
        self.ctx.enqueue_copy(dst_ptr=o.data.unsafe_ptr(), src_buf=ob)
        self.ctx.synchronize()
        return o^

    def crop(self, src: Mat[U8], x0: Int, y0: Int, w: Int, h: Int) raises -> Mat[U8]:
        var n = w * h * src.ch
        var a = self._up(src)
        var b = self.ctx.enqueue_create_buffer[DType.uint8](n)
        var p = P(Int32(src.rows), Int32(src.cols), Int32(src.ch), Int32(x0), Int32(y0), Int32(w), Int32(h), 0)
        self.ctx.enqueue_function[crop_k](_u(a), _u(b), p, grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[U8](h, w, src.ch, False)
        self._down(o, b)
        return o^

    def absdiff_u8(self, a: Mat[U8], b: Mat[U8]) raises -> Mat[U8]:
        var n = a.size()
        var da = self._up(a)
        var db = self._up(b)
        var o = self.ctx.enqueue_create_buffer[DType.uint8](n)
        self.ctx.enqueue_function[absdiff_u8_k](_u(da), _u(db), _u(o), Int32(n), grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var r = Mat[U8](a.rows, a.cols, a.ch, False)
        self._down(r, o)
        return r^

    def absdiff_f32(self, a: Mat[DType.float32], b: Mat[DType.float32]) raises -> Mat[DType.float32]:
        var n = a.size()
        var da = self.ctx.enqueue_create_buffer[DType.float32](n)
        var db = self.ctx.enqueue_create_buffer[DType.float32](n)
        var o = self.ctx.enqueue_create_buffer[DType.float32](n)
        self.ctx.enqueue_copy(dst_buf=da, src_ptr=a.data.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=db, src_ptr=b.data.unsafe_ptr())
        self.ctx.enqueue_function[absdiff_f32_k](F(unsafe_from_address=Int(da.unsafe_ptr())), F(unsafe_from_address=Int(db.unsafe_ptr())), F(unsafe_from_address=Int(o.unsafe_ptr())), Int32(n), grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var r = Mat[DType.float32](a.rows, a.cols, a.ch, False)
        self.ctx.enqueue_copy(dst_ptr=r.data.unsafe_ptr(), src_buf=o)
        self.ctx.synchronize()
        return r^

    def evm(self, orig: Mat[DType.float32], sm: Mat[DType.float32], mut st: Mat[DType.float64], init: Bool, alpha: Float64, lo: Float64, hi: Float64) raises -> Mat[DType.float32]:
        """hyper.evm_run on the card: upload the frames and the state, one thread per pixel, download both."""
        var n = orig.size()
        var np_ = orig.rows * orig.cols
        var da = self.ctx.enqueue_create_buffer[DType.float32](n)
        var db = self.ctx.enqueue_create_buffer[DType.float32](n)
        var dc = self.ctx.enqueue_create_buffer[DType.float32](n)
        var ds = self.ctx.enqueue_create_buffer[DType.float64](np_ * 2)
        self.ctx.enqueue_copy(dst_buf=da, src_ptr=orig.data.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=db, src_ptr=sm.data.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=ds, src_ptr=st.data.unsafe_ptr())
        var p = P(Int32(np_), Int32(orig.ch), Int32(1 if init else 0), 0, 0, 0, 0, 0)
        self.ctx.enqueue_function[evm_k](F(unsafe_from_address=Int(da.unsafe_ptr())), F(unsafe_from_address=Int(db.unsafe_ptr())), F(unsafe_from_address=Int(dc.unsafe_ptr())), D(unsafe_from_address=Int(ds.unsafe_ptr())), p, alpha, lo, hi, grid_dim=ceildiv(np_, THREADS), block_dim=THREADS)
        var o = Mat[DType.float32](orig.rows, orig.cols, orig.ch, False)
        self.ctx.enqueue_copy(dst_ptr=o.data.unsafe_ptr(), src_buf=dc)
        self.ctx.enqueue_copy(dst_ptr=st.data.unsafe_ptr(), src_buf=ds)
        self.ctx.synchronize()
        _ = (da.unsafe_ptr(), db.unsafe_ptr(), dc.unsafe_ptr(), ds.unsafe_ptr())
        return o^

    def resize_u8(self, src: Mat[U8], dw: Int, dh: Int) raises -> Mat[U8]:
        """cv2 INTER_LINEAR for uint8 ch 1, 3, 4: the CPU's own tap tables (_fx_taps), weights as int32."""
        var xi = List[Int]()
        var xw = List[Float32]()
        var yi = List[Int]()
        var yw = List[Float32]()
        _fx_taps(src.cols, dw, True, xi, xw)
        _fx_taps(src.rows, dh, False, yi, yw)
        var hx = List[Int32](length=dw * 4, fill=0)
        var hy = List[Int32](length=dh * 4, fill=0)
        for d in range(dw):
            hx[4 * d] = Int32(xi[2 * d])
            hx[4 * d + 1] = Int32(xi[2 * d + 1])
            hx[4 * d + 2] = Int32(xw[2 * d])
            hx[4 * d + 3] = Int32(xw[2 * d + 1])
        for d in range(dh):
            hy[4 * d] = Int32(yi[2 * d])
            hy[4 * d + 1] = Int32(yi[2 * d + 1])
            hy[4 * d + 2] = Int32(yw[2 * d])
            hy[4 * d + 3] = Int32(yw[2 * d + 1])
        var n = dw * dh * src.ch
        var a = self._up(src)
        var tx = self.ctx.enqueue_create_buffer[DType.int32](dw * 4)
        var ty = self.ctx.enqueue_create_buffer[DType.int32](dh * 4)
        self.ctx.enqueue_copy(dst_buf=tx, src_ptr=hx.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=ty, src_ptr=hy.unsafe_ptr())
        var b = self.ctx.enqueue_create_buffer[DType.uint8](n)
        var p = P(Int32(src.rows), Int32(src.cols), Int32(src.ch), Int32(dh), Int32(dw), 0, 0, 0)
        self.ctx.enqueue_function[resize_u8_k](_u(a), _u(b), I(unsafe_from_address=Int(tx.unsafe_ptr())), I(unsafe_from_address=Int(ty.unsafe_ptr())), p, grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[U8](dh, dw, src.ch, False)
        self._down(o, b)
        _ = (len(hx), len(hy))
        return o^

    def resize_f32(self, src: Mat[DType.float32], dw: Int, dh: Int) raises -> Mat[DType.float32]:
        """The CPU's float path for INTER_LINEAR (Taps kind 1): rows then columns, float32."""
        var tx = Taps(src.cols, dw, Float64(src.cols) / Float64(dw), 1)
        var ty = Taps(src.rows, dh, Float64(src.rows) / Float64(dh), 1)
        var hxi = List[Int32](length=dw * 2, fill=0)
        var hyi = List[Int32](length=dh * 2, fill=0)
        for i in range(dw * 2):
            hxi[i] = Int32(tx.idx[i])
        for i in range(dh * 2):
            hyi[i] = Int32(ty.idx[i])
        var n = dw * dh * src.ch
        var a = self.ctx.enqueue_create_buffer[DType.float32](src.size())
        self.ctx.enqueue_copy(dst_buf=a, src_ptr=src.data.unsafe_ptr())
        var bxi = self.ctx.enqueue_create_buffer[DType.int32](dw * 2)
        var byi = self.ctx.enqueue_create_buffer[DType.int32](dh * 2)
        var bxw = self.ctx.enqueue_create_buffer[DType.float32](dw * 2)
        var byw = self.ctx.enqueue_create_buffer[DType.float32](dh * 2)
        self.ctx.enqueue_copy(dst_buf=bxi, src_ptr=hxi.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=byi, src_ptr=hyi.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=bxw, src_ptr=tx.w.unsafe_ptr())
        self.ctx.enqueue_copy(dst_buf=byw, src_ptr=ty.w.unsafe_ptr())
        var b = self.ctx.enqueue_create_buffer[DType.float32](n)
        var p = P(Int32(src.rows), Int32(src.cols), Int32(src.ch), Int32(dh), Int32(dw), 0, 0, 0)
        self.ctx.enqueue_function[resize_f32_k](F(unsafe_from_address=Int(a.unsafe_ptr())), F(unsafe_from_address=Int(b.unsafe_ptr())), I(unsafe_from_address=Int(bxi.unsafe_ptr())), F(unsafe_from_address=Int(bxw.unsafe_ptr())), I(unsafe_from_address=Int(byi.unsafe_ptr())), F(unsafe_from_address=Int(byw.unsafe_ptr())), p, grid_dim=ceildiv(n, THREADS), block_dim=THREADS)
        var o = Mat[DType.float32](dh, dw, src.ch, False)
        self.ctx.enqueue_copy(dst_ptr=o.data.unsafe_ptr(), src_buf=b)
        self.ctx.synchronize()
        _ = (len(hxi), len(hyi), len(tx.w), len(ty.w))
        return o^


def crop_cpu(src: Mat[U8], x0: Int, y0: Int, w: Int, h: Int) -> Mat[U8]:
    var o = Mat[U8](h, w, src.ch, False)
    for y in range(h):
        for i in range(w * src.ch):
            o.data[y * w * src.ch + i] = src.data[((y0 + y) * src.cols + x0) * src.ch + i]
    return o^


def _run_fs2(mut a: Args) raises -> Bool:
    """gpu=1 on absdiff (uint8, float32; two inputs of one shape) and resize (interp 1: uint8 ch 1, 3, 4 with both sides >= 2,
    float32 ch 1, 3, 4). False: the CPU op runs (any other dtype, interp, channel count, shape, or no accelerator)."""
    var code = peek_code(a.ins[0])
    if code != 0 and code != 1:
        return False
    if a.op == "absdiff":
        if len(a.ins) != 2 or peek_code(a.ins[1]) != code:
            return False
        try:
            if code == 0:
                var x = load[U8](a.ins[0])
                var y = load[U8](a.ins[1])
                if not x.same_shape(y) or x.size() == 0:
                    return False
                var g = Gpu()
                var o = Mat[U8](0, 0)
                while a.again():
                    o = g.absdiff_u8(x, y)
                print("GPU-ARM absdiff uint8")
                save(o, a.out)
            else:
                var x = load[DType.float32](a.ins[0])
                var y = load[DType.float32](a.ins[1])
                if not x.same_shape(y) or x.size() == 0:
                    return False
                var g = Gpu()
                var o = Mat[DType.float32](0, 0)
                while a.again():
                    o = g.absdiff_f32(x, y)
                print("GPU-ARM absdiff float32")
                save(o, a.out)
            return True
        except e:
            print("gpu: no device (" + String(e) + "), CPU path")
            return False
    # resize
    if a.i("interp", 1) != 1:
        return False
    try:
        if code == 0:
            var m = load[U8](a.ins[0])
            var dw = a.i("w", m.cols)
            var dh = a.i("h", m.rows)
            if not (m.ch == 1 or m.ch == 3 or m.ch == 4) or m.cols < 2 or m.rows < 2 or dw < 1 or dh < 1:
                return False
            var g = Gpu()
            var o = Mat[U8](0, 0)
            while a.again():
                o = g.resize_u8(m, dw, dh)
            print("GPU-ARM resize uint8")
            save(o, a.out)
        else:
            var m = load[DType.float32](a.ins[0])
            var dw = a.i("w", m.cols)
            var dh = a.i("h", m.rows)
            if not (m.ch == 1 or m.ch == 3 or m.ch == 4) or m.cols < 1 or m.rows < 1 or dw < 1 or dh < 1:
                return False
            var g = Gpu()
            var o = Mat[DType.float32](0, 0)
            while a.again():
                o = g.resize_f32(m, dw, dh)
            print("GPU-ARM resize float32")
            save(o, a.out)
        return True
    except e:
        print("gpu: no device (" + String(e) + "), CPU path")
        return False


def _run_evm(mut a: Args) raises -> Bool:
    """gpu=1 on evm (float32 clip, 2 or more frames) and evmStep (one float32 frame, STATE float64 x2 or absent): the spatial blur is
    the CPU's (hyper.evm_blur, same values), the temporal filter runs on the card. False: the CPU op runs and raises its own errors."""
    if peek_code(a.ins[0]) != 1:
        return False
    var x = load[DType.float32](a.ins[0])
    var lo = a.f("lo", 0.05)
    var hi = a.f("hi", 0.4)
    var step = a.op == "evmStep"
    if x.size() == 0 or not (0.0 < lo and lo < hi and hi <= 1.0) or (x.ch < 2 if not step else x.ch != 1):
        return False
    var st = Mat[DType.float64](x.rows, x.cols, 2)
    if step and len(a.ins) > 1:
        if peek_code(a.ins[1]) != 3:
            return False
        st = load[DType.float64](a.ins[1])
        if st.rows != x.rows or st.cols != x.cols or st.ch != 2:
            return False
    try:
        var g = Gpu()
        var sm = evm_blur(x, a.f("sigma", 0.0))
        var o = Mat[DType.float32](0, 0)
        while a.again():
            if not step:
                st = Mat[DType.float64](x.rows, x.cols, 2)
            o = g.evm(x, sm, st, not step or len(a.ins) < 2, a.f("alpha", 20.0), lo, hi)
        print("GPU-ARM evm float32")
        save(o, a.out)
        if step:
            save(st, a.out + ".1")
        return True
    except e:
        print("gpu: no device (" + String(e) + "), CPU path")
        return False


def run(mut a: Args) raises -> Bool:
    """gpu=1 on cvtColor (bgr2gray, rgb2gray), Sobel (ksize 3, scale 1, dx or dy), boxDown, sharpness; crop on both. Returns False
    (the CPU op runs) for anything else, for no gpu=1 and for no accelerator."""
    if run_stream(a):
        return True
    var want = a.i("gpu", 0) == 1
    if want and (a.op == "absdiff" or a.op == "resize"):
        return _run_fs2(a)
    if want and (a.op == "evm" or a.op == "evmStep") and len(a.ins) > 0:
        return _run_evm(a)
    if a.op == "crop":
        var m = load[U8](a.ins[0])
        var x0 = a.i("x", 0)
        var y0 = a.i("y", 0)
        var w = a.i("w", 0)
        var h = a.i("h", 0)
        if x0 < 0 or y0 < 0 or w < 1 or h < 1 or x0 + w > m.cols or y0 + h > m.rows:
            raise Error("crop: window " + String(w) + "x" + String(h) + "+" + String(x0) + "+" + String(y0) + " outside " + String(m.cols) + "x" + String(m.rows))
        var o = Mat[U8](0, 0)
        if want:
            try:
                var g = Gpu()
                while a.again():
                    o = g.crop(m, x0, y0, w, h)
                print("GPU-ARM crop")
                save(o, a.out)
                return True
            except e:
                print("gpu: no device (" + String(e) + "), CPU path")
        while a.again():
            o = crop_cpu(m, x0, y0, w, h)
        save(o, a.out)
        return True
    if not want or not (a.op in ["cvtColor", "Sobel", "boxDown", "sharpness"]):
        return False
    if peek_code(a.ins[0]) != 0:  # the kernels are uint8; float and int rows stay on the CPU
        return False
    var m = load[U8](a.ins[0])
    var ok = False
    if a.op == "cvtColor":
        var code = cvt_code(a.s("code", ""))
        ok = m.ch == 3 and (code == 0 or code == 1) and m.rows * m.cols > 0
    elif a.op == "Sobel":
        var dx = a.i("dx", 1)
        var dy = a.i("dy", 0)
        ok = m.ch == 1 and a.i("ksize", 3) == 3 and a.f("scale", 1.0) == 1.0 and dx + dy == 1 and m.rows >= 2 and m.cols >= 2
    elif a.op == "boxDown":
        var f = a.i("f", 2)
        ok = m.ch == 1 and f >= 1 and m.rows >= f and m.cols >= f
    else:
        var t = a.i("tile", 32)
        ok = m.ch == 1 and t >= 2 and m.rows >= 3 and m.cols >= 3 and (m.rows - 2) // t >= 1 and (m.cols - 2) // t >= 1
    if not ok:
        return False
    try:
        var g = Gpu()
        if a.op == "sharpness":
            var o = Mat[DType.float64](0, 0)
            while a.again():
                o = g.sharpness(m, a.i("tile", 32), a.f("thr", 10.0))
            save(o, a.out)
        elif a.op == "Sobel":
            var o = Mat[DType.int16](0, 0)
            while a.again():
                o = g.sobel3(m, a.i("dx", 1))
            save(o, a.out)
        else:
            var o = Mat[U8](0, 0)
            while a.again():
                if a.op == "cvtColor":
                    o = g.gray(m, cvt_code(a.s("code", "")) == 1)
                else:
                    o = g.box_down(m, a.i("f", 2))
            save(o, a.out)
        print("GPU-ARM " + a.op)
        return True
    except e:
        print("gpu: no device (" + String(e) + "), CPU path")
        return False
