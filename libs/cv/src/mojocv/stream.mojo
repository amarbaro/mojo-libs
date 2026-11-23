# stream: the front end of a frame stream (R4). Per frame pair it answers one question on the CPU: which tiles changed.
# A tile is dirty when the largest |a - b| over its pixels and channels is above a threshold (largest over all bytes of the tile:
# the largest over channels of the largest over pixels is the same number). Border tiles are the partial ones the grid leaves.
# `streamDirty OUT A B [tile=16 thr=16]` writes the tile maxima (uint8, ceil(rows / tile) x ceil(cols / tile)) and, in OUT.1, the
# mask (255 where max > thr). `streamRun OUT F1 F2 ... [tile thr keyfrac maxgap]` runs the keyframe state machine over the frames
# and writes one row per frame (decision, dirty tiles, tiles, largest change among the clean tiles) and the reference after the last.
# Decisions: KEY 0 (first frame, a new shape, a scene cut: dirty share >= keyfrac, or maxgap frames since the last key), SKIP 1 (no
# tile dirty), DELTA 2 (some tiles dirty: only those tiles of the reference are replaced, so a slow drift below the threshold
# accumulates against the reference and shows up at the frame it crosses). The clean-tile maximum is the activity the threshold
# let through: a caller that cares sees it. Dispatched from gpu.run (main.mojo has another owner); no GPU arm, the pair is memory bound.
from std.sys.info import simd_width_of
from mojocv.mat import Mat, load, save
from mojocv.core import Args, peek_code, par

comptime U8 = DType.uint8
comptime KEY = 0
comptime SKIP = 1
comptime DELTA = 2


def tile_grid(n: Int, tile: Int) -> Int:
    return (n + tile - 1) // tile


def tile_max(a: Mat[U8], b: Mat[U8], tile: Int) raises -> Mat[U8]:
    """Largest |a - b| per tile: one uint8 per tile of tile x tile pixels (the grid's last row and column hold the partial tiles)."""
    if not a.same_shape(b):
        raise Error("stream: frame shapes differ")
    if tile < 1:
        raise Error("stream: tile must be at least 1")
    var R = tile_grid(a.rows, tile)
    var C = tile_grid(a.cols, tile)
    var o = Mat[U8](R, C, 1)
    var pa = a.ptr()
    var pb = b.ptr()
    var po = o.ptr()
    var rows = a.rows
    var rn = a.cols * a.ch
    var tn = tile * a.ch
    comptime W = simd_width_of[U8]()

    def trow(t: Int) {imm}:
        var y1 = min(t * tile + tile, rows)
        for c in range(C):
            var x0 = c * tn
            var x1 = min(x0 + tn, rn)
            var m = SIMD[U8, W](0)
            var ms = UInt8(0)
            for y in range(t * tile, y1):
                var i = y * rn + x0
                var e = y * rn + x1
                while i + W <= e:
                    var x = pa.unsafe_load[width=W](i)
                    var z = pb.unsafe_load[width=W](i)
                    m = max(m, max(x, z) - min(x, z))
                    i += W
                while i < e:
                    var x = pa[unsafe_offset=i]
                    var z = pb[unsafe_offset=i]
                    ms = max(ms, max(x, z) - min(x, z))
                    i += 1
            po[unsafe_offset=t * C + c] = max(m.reduce_max(), ms)

    par(trow, R)
    _ = (len(a.data), len(b.data))
    return o^


def dirty_mask(tm: Mat[U8], thr: Int) -> Mat[U8]:
    var o = Mat[U8](tm.rows, tm.cols, 1)
    for i in range(tm.size()):
        o.data[i] = 255 if Int(tm.data[i]) > thr else 0
    return o^


struct Stream(Movable):
    """The keyframe state: a reference frame (the last key with the dirty tiles of every later frame merged in), the frames since
    the last key, and what the last push saw."""

    var tile: Int
    var thr: Int
    var key_frac: Float64
    var max_gap: Int
    var base: Mat[U8]
    var have: Bool
    var since: Int
    var n_dirty: Int
    var n_tiles: Int
    var sub_max: Int

    def __init__(out self, tile: Int, thr: Int, key_frac: Float64, max_gap: Int):
        self.tile = tile
        self.thr = thr
        self.key_frac = key_frac
        self.max_gap = max_gap
        self.base = Mat[U8](0, 0, 1)
        self.have = False
        self.since = 0
        self.n_dirty = 0
        self.n_tiles = 0
        self.sub_max = 0

    def _merge(mut self, f: Mat[U8], tm: Mat[U8]):
        """Copy the dirty tiles of f into the reference."""
        var rn = f.cols * f.ch
        var tn = self.tile * f.ch
        for t in range(tm.rows):
            for c in range(tm.cols):
                if Int(tm.data[t * tm.cols + c]) > self.thr:
                    var x0 = c * tn
                    var x1 = min(x0 + tn, rn)
                    for y in range(t * self.tile, min(t * self.tile + self.tile, f.rows)):
                        for i in range(y * rn + x0, y * rn + x1):
                            self.base.data[i] = f.data[i]

    def push(mut self, f: Mat[U8]) raises -> Int:
        self.n_tiles = tile_grid(f.rows, self.tile) * tile_grid(f.cols, self.tile)
        if not self.have or not self.base.same_shape(f):
            self.base = Mat[U8](copy=f)
            self.have = True
            self.since = 0
            self.n_dirty = self.n_tiles
            self.sub_max = 0
            return KEY
        var tm = tile_max(self.base, f, self.tile)
        var nd = 0
        var sm = 0
        for i in range(tm.size()):
            var v = Int(tm.data[i])
            if v > self.thr:
                nd += 1
            else:
                sm = max(sm, v)
        self.n_dirty = nd
        self.sub_max = sm
        self.since += 1
        var forced = self.max_gap > 0 and self.since >= self.max_gap
        var cut = self.key_frac > 0 and nd > 0 and Float64(nd) >= self.key_frac * Float64(self.n_tiles)
        if forced or cut:
            self.base = Mat[U8](copy=f)
            self.since = 0
            return KEY
        if nd == 0:
            return SKIP
        self._merge(f, tm)
        return DELTA


def run(mut a: Args) raises -> Bool:
    if a.op != "streamDirty" and a.op != "streamRun":
        return False
    var tile = a.i("tile", 16)
    var thr = a.i("thr", 16)
    if a.op == "streamDirty":
        if len(a.ins) != 2 or peek_code(a.ins[0]) != 0 or peek_code(a.ins[1]) != 0:
            raise Error("streamDirty: two uint8 frames")
        var x = load[U8](a.ins[0])
        var y = load[U8](a.ins[1])
        var tm = Mat[U8](0, 0)
        while a.again():
            tm = tile_max(x, y, tile)
        save(tm, a.out)
        save(dirty_mask(tm, thr), a.out + ".1")
        return True
    if len(a.ins) < 1:
        raise Error("streamRun: at least one frame")
    var s = Stream(tile, thr, a.f("keyfrac", 0.5), a.i("maxgap", 30))
    var o = Mat[DType.int32](len(a.ins), 4, 1)
    for k in range(len(a.ins)):
        if peek_code(a.ins[k]) != 0:
            raise Error("streamRun: uint8 frames")
        var d = s.push(load[U8](a.ins[k]))
        o.data[4 * k] = Int32(d)
        o.data[4 * k + 1] = Int32(s.n_dirty)
        o.data[4 * k + 2] = Int32(s.n_tiles)
        o.data[4 * k + 3] = Int32(s.sub_max)
    save(o, a.out)
    save(s.base, a.out + ".1")
    return True
