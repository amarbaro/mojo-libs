# gpustock: the GPU half of `stockBatch gpu=1`. libjpeg-turbo decodes a JPEG to its planes on a CPU thread (Huffman and IDCT,
# tj3DecompressToYUVPlanes8); the planes go up once and the card does the decode tail and the full-size stock ops on the
# resident picture: libjpeg's fancy upsampling (jdsample.c h2v1, h2v2) and YCbCr -> BGR (jdcolor.c tables, 16-bit fixed point),
# cv2's integer grey, the colour sums of colorCast, the row sums of blockiness, the box sums of the two hashes and the area
# shrink to the analysis scale. Only those sums and the analysis-scale grey come back; stockcheck.mojo runs the rest on the CPU.
# All integer arithmetic in libjpeg's and the CPU ops' order: the BGR bytes equal tj3Decompress8, the numbers equal gpu=0.
from std.math import ceildiv
from std.memory import stack_allocation
from max.gpu import block_idx, thread_idx, lane_id, WARP_SIZE
from max.gpu.sync import barrier
from max.gpu.primitives import warp
from max.gpu.memory import AddressSpace
from max.gpu.host import DeviceContext
from mojocv.mat import Mat
from mojocv.gpu import U, L, P, THREADS, boxdown_k, _u
from mojocv.jpegio import Yuv

comptime RG = 16  # picture rows per thread in ycc_k
comptime NCELL = 72 + 1024  # dHash 8 x 9 cells, then pHash 32 x 32
comptime SH = MutPointer[Int64, MutUntrackedOrigin, address_space=AddressSpace.SHARED]


def _bsum(v: Int64, sh: SH) -> Int64:
    """Sum over the 256-thread block (8 waves of 32); every thread gets the total."""
    var w = warp.sum(v)
    if lane_id() == 0:
        sh[unsafe_offset=Int(thread_idx.x // WARP_SIZE)] = w
    barrier()
    var t = Int64(0)
    comptime for k in range(THREADS // 32):
        t += sh[unsafe_offset=k]
    barrier()
    return t


def _up(c: U, o: Int32, cw: Int32, chh: Int32, x: Int32, y: Int32, mode: Int32) -> Int32:
    """One output sample of libjpeg's fancy upsampling of the chroma plane at offset o: h2v1 (mode 1, 4:2:2: 3/4 near + 1/4 far,
    +1 or +2), h2v2 (mode 2, 4:2:0: the same with 3:1 column sums, +8 or +7, >> 4), edge columns and rows replicated as
    jdsample.c and jdmainct.c do; mode 0 (4:4:4) reads the sample."""
    if mode == 0:
        return Int32(c[unsafe_offset=Int(o + y * cw + x)])
    var cx = x >> 1
    var odd = (x & 1) == 1
    var nx = cx + 1 if odd else cx - 1
    var edge = nx < 0 or nx >= cw
    if mode == 1:
        var r = o + y * cw
        var a = Int32(c[unsafe_offset=Int(r + cx)])
        if edge:
            return a
        return (3 * a + Int32(c[unsafe_offset=Int(r + nx)]) + Int32(2 if odd else 1)) >> 2
    var cy = y >> 1
    var ny = min(max(cy + 1 if (y & 1) == 1 else cy - 1, Int32(0)), chh - 1)
    var r0 = o + cy * cw
    var r1 = o + ny * cw
    var t = 3 * Int32(c[unsafe_offset=Int(r0 + cx)]) + Int32(c[unsafe_offset=Int(r1 + cx)])
    if edge:
        return (4 * t + Int32(7 if odd else 8)) >> 4
    var u = 3 * Int32(c[unsafe_offset=Int(r0 + nx)]) + Int32(c[unsafe_offset=Int(r1 + nx)])
    return (3 * t + u + Int32(7 if odd else 8)) >> 4


def ycc_k(yuv: U, grey: U, bgr: U, part: L, p: P, want: Int32):
    """One thread per column of RG rows: upsample, YCbCr -> BGR (ycc_rgb_convert), grey (B 3735 + G 19235 + R 9798 + 16384) >> 15,
    BGR written only when want = 1; the block's B, G, R sums go to part. p: w h ys cw ch mode ocb ocr."""
    var sh = stack_allocation[THREADS // 32, Int64, address_space=AddressSpace.SHARED]()
    var w = p[0]
    var h = p[1]
    var nbx = (w + THREADS - 1) // THREADS
    var bx = Int32(block_idx.x) % nbx
    var by = Int32(block_idx.x) // nbx
    var x = bx * THREADS + Int32(thread_idx.x)
    var sb = Int64(0)
    var sg = Int64(0)
    var sr = Int64(0)
    if x < w:
        for k in range(RG):
            var y = by * RG + Int32(k)
            if y >= h:
                break
            var lum = Int32(yuv[unsafe_offset=Int(y * p[2] + x)])
            var b = lum
            var g = lum
            var r = lum
            if p[5] != 3:
                var cb = _up(yuv, p[6], p[3], p[4], x, y, p[5]) - 128
                var cr = _up(yuv, p[7], p[3], p[4], x, y, p[5]) - 128
                r = min(max(lum + ((91881 * cr + 32768) >> 16), Int32(0)), Int32(255))
                g = min(max(lum + ((-22554 * cb - 46802 * cr + 32768) >> 16), Int32(0)), Int32(255))
                b = min(max(lum + ((116130 * cb + 32768) >> 16), Int32(0)), Int32(255))
            var e = Int(y) * Int(w) + Int(x)
            if want != 0:
                bgr[unsafe_offset=3 * e] = UInt8(b)
                bgr[unsafe_offset=3 * e + 1] = UInt8(g)
                bgr[unsafe_offset=3 * e + 2] = UInt8(r)
            grey[unsafe_offset=e] = UInt8((b * 3735 + g * 19235 + r * 9798 + 16384) >> 15)
            sb += Int64(b)
            sg += Int64(g)
            sr += Int64(r)
    var tb = _bsum(sb, sh)
    var tg = _bsum(sg, sh)
    var tr = _bsum(sr, sh)
    if thread_idx.x == 0:
        part[unsafe_offset=3 * Int(block_idx.x)] = tb
        part[unsafe_offset=3 * Int(block_idx.x) + 1] = tg
        part[unsafe_offset=3 * Int(block_idx.x) + 2] = tr


def blk_k(grey: U, res: L, p: P):
    """One block per row y of the native grey: sums of |g[x+1] - g[x]| at x % 8 == 7 and elsewhere, and of |g[y+1][x] - g[y][x]|
    (blockiness' four sums before the 8-row split). p: rows cols."""
    var sh = stack_allocation[THREADS // 32, Int64, address_space=AddressSpace.SHARED]()
    var y = Int(block_idx.x)
    var C = Int(p[1])
    var r = y * C
    var hb = Int64(0)
    var hn = Int64(0)
    var vs = Int64(0)
    for x in range(Int(thread_idx.x), C - 1, THREADS):
        var e = Int64(grey[unsafe_offset=r + x + 1]) - Int64(grey[unsafe_offset=r + x])
        e = e if e >= 0 else -e
        if x % 8 == 7:
            hb += e
        else:
            hn += e
    if y < Int(p[0]) - 1:
        for x in range(Int(thread_idx.x), C, THREADS):
            var e = Int64(grey[unsafe_offset=r + C + x]) - Int64(grey[unsafe_offset=r + x])
            vs += e if e >= 0 else -e
    var a = _bsum(hb, sh)
    var b = _bsum(hn, sh)
    var c = _bsum(vs, sh)
    if thread_idx.x == 0:
        res[unsafe_offset=3 * y] = a
        res[unsafe_offset=3 * y + 1] = b
        res[unsafe_offset=3 * y + 2] = c


def cells_k(grey: U, res: L, p: P):
    """One block per hash cell: the pixel sum of cell (i, j) = rows [i R // gh, (i+1) R // gh), cols likewise; cells 0..71 are the
    8 x 9 dHash grid, 72.. the 32 x 32 pHash grid. p: rows cols."""
    var sh = stack_allocation[THREADS // 32, Int64, address_space=AddressSpace.SHARED]()
    var k = Int(block_idx.x)
    var R = Int(p[0])
    var C = Int(p[1])
    var gh = 8 if k < 72 else 32
    var gw = 9 if k < 72 else 32
    var c = k if k < 72 else k - 72
    var i = c // gw
    var j = c % gw
    var s = Int64(0)
    for yy in range(i * R // gh, (i + 1) * R // gh):
        for xx in range(j * C // gw + Int(thread_idx.x), (j + 1) * C // gw, THREADS):
            s += Int64(grey[unsafe_offset=yy * C + xx])
    var t = _bsum(s, sh)
    if thread_idx.x == 0:
        res[unsafe_offset=k] = t


struct GpuRes(Movable):
    """What one picture brings back: the analysis-scale grey, B, G, R sums, blockiness row sums (3 per row), hash cell sums,
    and the BGR picture when it was asked for."""
    var ga: Mat[DType.uint8]
    var cast: List[Int64]
    var blk: List[Int64]
    var cells: List[Int64]
    var bgr: Mat[DType.uint8]

    def __init__(out self):
        self.ga = Mat[DType.uint8](0, 0)
        self.cast = List[Int64]()
        self.blk = List[Int64]()
        self.cells = List[Int64]()
        self.bgr = Mat[DType.uint8](0, 0)


struct StockGpu:
    var ctx: DeviceContext

    def __init__(out self) raises:
        self.ctx = DeviceContext()  # raises when there is no accelerator

    def analyse(self, y: Yuv, f: Int, want: Bool) raises -> GpuRes:
        """Upload the planes, run the tail and the full-size ops, download the results (one synchronize)."""
        var w = y.w
        var h = y.h
        var n = w * h
        var dy = self.ctx.enqueue_create_buffer[DType.uint8](len(y.data))
        self.ctx.enqueue_copy(dst_buf=dy, src_ptr=y.data.unsafe_ptr())
        var dg = self.ctx.enqueue_create_buffer[DType.uint8](n)
        var db = self.ctx.enqueue_create_buffer[DType.uint8](n * 3 if want else 1)
        var nb = ceildiv(w, THREADS) * ceildiv(h, RG)
        var dp = self.ctx.enqueue_create_buffer[DType.int64](nb * 3)
        var p = P(Int32(w), Int32(h), Int32(y.ys), Int32(y.cw), Int32(y.ch), Int32(y.mode), Int32(y.ocb), Int32(y.ocr))
        self.ctx.enqueue_function[ycc_k](_u(dy), _u(dg), _u(db), L(unsafe_from_address=Int(dp.unsafe_ptr())), p, Int32(1 if want else 0), grid_dim=nb, block_dim=THREADS)
        var R = h // f
        var C = w // f
        var da = self.ctx.enqueue_create_buffer[DType.uint8](R * C)
        self.ctx.enqueue_function[boxdown_k](_u(dg), _u(da), P(Int32(h), Int32(w), 1, Int32(f), Int32(R), Int32(C), 0, 0), grid_dim=ceildiv(R * C, THREADS), block_dim=THREADS)
        var dk = self.ctx.enqueue_create_buffer[DType.int64](3 * h)
        var dc = self.ctx.enqueue_create_buffer[DType.int64](NCELL)
        var q = P(Int32(h), Int32(w), 0, 0, 0, 0, 0, 0)
        self.ctx.enqueue_function[blk_k](_u(dg), L(unsafe_from_address=Int(dk.unsafe_ptr())), q, grid_dim=h, block_dim=THREADS)
        self.ctx.enqueue_function[cells_k](_u(dg), L(unsafe_from_address=Int(dc.unsafe_ptr())), q, grid_dim=NCELL, block_dim=THREADS)
        var o = GpuRes()
        o.ga = Mat[DType.uint8](R, C, 1, False)
        var part = List[Int64](length=nb * 3, fill=0)
        o.blk = List[Int64](length=3 * h, fill=0)
        o.cells = List[Int64](length=NCELL, fill=0)
        self.ctx.enqueue_copy(dst_ptr=o.ga.data.unsafe_ptr(), src_buf=da)
        self.ctx.enqueue_copy(dst_ptr=part.unsafe_ptr(), src_buf=dp)
        self.ctx.enqueue_copy(dst_ptr=o.blk.unsafe_ptr(), src_buf=dk)
        self.ctx.enqueue_copy(dst_ptr=o.cells.unsafe_ptr(), src_buf=dc)
        if want:
            o.bgr = Mat[DType.uint8](h, w, 3, False)
            self.ctx.enqueue_copy(dst_ptr=o.bgr.data.unsafe_ptr(), src_buf=db)
        self.ctx.synchronize()
        o.cast = List[Int64](length=3, fill=0)
        for i in range(nb):
            for c in range(3):
                o.cast[c] += part[3 * i + c]
        return o^
