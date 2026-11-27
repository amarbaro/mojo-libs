# jpegyuv: a plain JPEG decoded only to its planes (Huffman and IDCT in libturbojpeg, tj3DecompressToYUVPlanes8), for the GPU
# tail of `stockBatch gpu=1` (gpustock.mojo: upsampling, colour, grey and the stock sums on the card). The checks and the
# "jpeg-fallback" reasons are jpegio.load_jpeg's (same EXIF, ICC and CMYK rules), so a file falls back the same way on both paths.
# jpegio.load_jpeg is pure Mojo now (_jpeg_baseline); the tj3 constants and the EXIF reader live here until this path
# takes its planes from _jpeg_baseline too.
from std.ffi import OwnedDLHandle, RTLD

comptime _DEEPBIND = 0x8
comptime _INIT_DECOMPRESS = 1
comptime _P_WIDTH = 5
comptime _P_HEIGHT = 6
comptime _P_COLORSPACE = 8
comptime _CS_CMYK = 3
comptime _CS_YCCK = 4


def _exif_orientation(d: List[UInt8]) -> Int:
    """EXIF orientation of IFD0 (tag 0x0112), 1 when absent or unreadable."""
    var p = 2
    while p + 4 <= len(d) and d[p] == 0xFF:
        var m = Int(d[p + 1])
        var ln = Int(d[p + 2]) << 8 | Int(d[p + 3])
        if m == 0xDA or m == 0xD9:
            break
        if m == 0xE1 and ln >= 16 and p + 2 + ln <= len(d) and d[p + 4] == 0x45 and d[p + 5] == 0x78 and d[p + 6] == 0x69 and d[p + 7] == 0x66:
            var t = p + 10  # TIFF header
            var le = d[t] == 0x49

            def rd(at: Int, n: Int) capturing -> Int:
                var v = 0
                for k in range(n):
                    v |= Int(d[at + (k if le else n - 1 - k)]) << (8 * k)
                return v

            var end = p + 2 + ln
            var ifd = t + rd(t + 4, 4)
            if ifd + 2 > end:
                return 1
            for e in range(rd(ifd, 2)):
                var q = ifd + 2 + 12 * e
                if q + 12 > end:
                    return 1
                if rd(q, 2) == 0x0112:
                    return rd(q + 8, 2)
            return 1
        p += 2 + ln
    return 1

comptime _P_SUBSAMP = 4
comptime _SAMP_444 = 0
comptime _SAMP_422 = 1
comptime _SAMP_420 = 2
comptime _SAMP_GRAY = 3


def _jpeg_open(d: List[UInt8], tj: OwnedDLHandle) raises -> Tuple[Int, String]:
    """(tj3 handle, reason to fall back or ""): the checks of jpegio.load_jpeg, repeated here (that file belongs to another lane)."""
    if len(d) < 4 or d[0] != 0xFF or d[1] != 0xD8:
        raise Error("jpeg-fallback: not a JPEG")
    var o = _exif_orientation(d)
    if o != 1:
        raise Error(String("jpeg-fallback: orientation ", o))
    var h = tj.call["tj3Init", Int](Int32(_INIT_DECOMPRESS))
    if h == 0:
        raise Error("jpeg-fallback: tj3Init")
    var why = String("")
    if tj.call["tj3DecompressHeader", Int32](h, d.unsafe_ptr(), len(d)) != 0:
        why = "header"
    else:
        var icc = 0
        var isz = 0
        if tj.call["tj3GetICCProfile", Int32](h, UnsafePointer(to=icc), UnsafePointer(to=isz)) == 0 and isz > 0:
            # img2mcv.sh converts only a profile whose description does not say sRGB; an sRGB one decodes as is
            var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=icc)
            var t = String("")
            for k in range(isz):
                if p[k] != 0:
                    t += chr(Int(p[k]) | 0x20 if p[k] >= 65 and p[k] <= 90 else Int(p[k]))
            if "srgb" not in t:
                why = "icc"
            tj.call["tj3Free", NoneType](icc)
        var cs = Int(tj.call["tj3Get", Int32](h, Int32(_P_COLORSPACE)))
        if not why and (cs == _CS_CMYK or cs == _CS_YCCK):
            why = "cmyk"
    return (h, why)


struct Yuv(Movable):
    """A JPEG's planes as libjpeg-turbo has them before upsampling and colour conversion (tj3DecompressToYUVPlanes8): Y at
    stride ys, Cb and Cr (cw x ch each, stride cw) at offsets ocb and ocr of one buffer. mode: 0 4:4:4, 1 4:2:2, 2 4:2:0, 3 grey."""
    var data: List[UInt8]
    var w: Int
    var h: Int
    var mode: Int
    var ys: Int
    var cw: Int
    var ch: Int
    var ocb: Int
    var ocr: Int
    var n: Int  # bytes of the three planes
    var ext: Int  # address of a caller's buffer holding them, 0: they are in data

    def addr(self) -> Int:
        return self.ext if self.ext != 0 else Int(self.data.unsafe_ptr())

    def __init__(out self):
        self.n = 0
        self.ext = 0
        self.data = List[UInt8]()
        self.w = 0
        self.h = 0
        self.mode = -1
        self.ys = 0
        self.cw = 0
        self.ch = 0
        self.ocb = 0
        self.ocr = 0


def load_jpeg_yuv(path: String, dst: Int = 0, cap: Int = 0) raises -> Yuv:
    """The planes of a plain JPEG (load_jpeg's checks, the same "jpeg-fallback" reasons). A sampling the GPU tail does not
    cover (4:4:0, 4:1:1, ...) or a chroma plane under 3 samples wide (libjpeg upsamples that one by boxes) raises "jpeg-cpu".
    dst, cap: a caller's buffer (pinned host memory) the planes go to when they fit, else a List of their own."""
    var d = open(path, "r").read_bytes()
    var tj = OwnedDLHandle("libturbojpeg.so.0", RTLD.NOW | _DEEPBIND)
    var r = _jpeg_open(d, tj)
    var h = r[0]
    var why = r[1]
    var y = Yuv()
    if not why:
        y.w = Int(tj.call["tj3Get", Int32](h, Int32(_P_WIDTH)))
        y.h = Int(tj.call["tj3Get", Int32](h, Int32(_P_HEIGHT)))
        var ss = Int(tj.call["tj3Get", Int32](h, Int32(_P_SUBSAMP)))
        y.mode = 0 if ss == _SAMP_444 else (1 if ss == _SAMP_422 else (2 if ss == _SAMP_420 else (3 if ss == _SAMP_GRAY else -1)))
        if y.mode >= 0:
            y.ys = Int(tj.call["tj3YUVPlaneWidth", Int32](Int32(0), Int32(y.w), Int32(ss)))
            y.ocb = y.ys * Int(tj.call["tj3YUVPlaneHeight", Int32](Int32(0), Int32(y.h), Int32(ss)))
            if y.mode != 3:
                y.cw = Int(tj.call["tj3YUVPlaneWidth", Int32](Int32(1), Int32(y.w), Int32(ss)))
                y.ch = Int(tj.call["tj3YUVPlaneHeight", Int32](Int32(1), Int32(y.h), Int32(ss)))
        if y.mode < 0 or (y.mode != 3 and y.cw < 3):
            why = "cpu"
        else:
            y.ocr = y.ocb + y.cw * y.ch
            y.n = y.ocr + y.cw * y.ch
            if dst != 0 and y.n <= cap:
                y.ext = dst
            else:
                y.data = List[UInt8](unsafe_uninit_length=y.n)
            var base = y.addr()
            var planes: List[Int] = [base, base + y.ocb, base + y.ocr]
            var strides: List[Int32] = [Int32(y.ys), Int32(y.cw), Int32(y.cw)]
            if tj.call["tj3DecompressToYUVPlanes8", Int32](h, d.unsafe_ptr(), len(d), planes.unsafe_ptr(), strides.unsafe_ptr()) != 0:
                why = "decode"
    tj.call["tj3Destroy", NoneType](h)
    _ = len(d)
    if why == "cpu":
        raise Error("jpeg-cpu: sampling")
    if why:
        raise Error("jpeg-fallback: " + why)
    return y^


