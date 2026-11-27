# In-process JPEG decode through the system libturbojpeg (tj3 API), loaded at run time, so no PPM/MCV file
# goes through the disk: the stock pre-check spent about half of its decode time writing and reading 61 MB
# PPM files (docs/gpu.md, decode section). Pixels equal libvips' and libjpeg's defaults (ISLOW DCT, fancy
# upsampling), which is what `vips autorot` used before.
# Only plain JPEGs are taken: an embedded ICC profile, CMYK/YCCK, an EXIF orientation other than 1 or
# any libturbojpeg error raises "jpeg-fallback: <why>", and the caller decodes that file the old way.
from std.ffi import OwnedDLHandle, RTLD
from mojocv.mat import Mat

comptime _DEEPBIND = 0x8
comptime _INIT_DECOMPRESS = 1
comptime _PF_BGR = 1
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


def load_jpeg(path: String) raises -> Mat[DType.uint8]:
    """BGR uint8 Mat of a plain JPEG, decoded in this process."""
    var d = open(path, "r").read_bytes()
    if len(d) < 4 or d[0] != 0xFF or d[1] != 0xD8:
        raise Error("jpeg-fallback: not a JPEG")
    var o = _exif_orientation(d)
    if o != 1:
        raise Error(String("jpeg-fallback: orientation ", o))
    var tj = OwnedDLHandle("libturbojpeg.so.0", RTLD.NOW | _DEEPBIND)
    var h = tj.call["tj3Init", Int](Int32(_INIT_DECOMPRESS))
    if h == 0:
        raise Error("jpeg-fallback: tj3Init")
    var why = String("")
    var m = Mat[DType.uint8](0, 0, 3, False)
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
        if not why:
            var w = Int(tj.call["tj3Get", Int32](h, Int32(_P_WIDTH)))
            var hh = Int(tj.call["tj3Get", Int32](h, Int32(_P_HEIGHT)))
            m = Mat[DType.uint8](hh, w, 3, False)
            if tj.call["tj3Decompress8", Int32](h, d.unsafe_ptr(), len(d), m.ptr(), Int32(w * 3), Int32(_PF_BGR)) != 0:
                why = "decode"
    tj.call["tj3Destroy", NoneType](h)
    _ = len(d)
    if why:
        raise Error("jpeg-fallback: " + why)
    return m^
