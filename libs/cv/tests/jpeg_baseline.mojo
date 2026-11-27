"""Pixel, error, and one-core decode checks. TurboJPEG is the test oracle."""
from std.ffi import OwnedDLHandle, RTLD
from std.os import SEEK_END
from std.sys import argv
from std.time import perf_counter_ns
from mojocv._jpeg_baseline import decode_baseline_jpeg
from mojocv.mat import Mat


def read_jpeg(path: String) raises -> List[UInt8]:
    var f = open(path, "r")
    var size = Int(f.seek(0, SEEK_END))
    _ = f.seek(0)
    return f.read_bytes(size)


def oracle(tj: OwnedDLHandle, bytes: List[UInt8]) raises -> Mat[DType.uint8]:
    var h = tj.call["tj3Init", Int](Int32(1))  # TJINIT_DECOMPRESS
    if h == 0:
        raise Error("tj3Init")
    # STOPONWARNING=1, FASTUPSAMPLE=0, FASTDCT=0 (ISLOW).
    var status = tj.call["tj3Set", Int32](h, Int32(0), Int32(1))
    status |= tj.call["tj3Set", Int32](h, Int32(9), Int32(0))
    status |= tj.call["tj3Set", Int32](h, Int32(10), Int32(0))
    status |= tj.call["tj3DecompressHeader", Int32](h, bytes.unsafe_ptr(), len(bytes))
    var output = Mat[DType.uint8](0, 0, 3, False)
    if status == 0:
        var w = Int(tj.call["tj3Get", Int32](h, Int32(5)))
        var rows = Int(tj.call["tj3Get", Int32](h, Int32(6)))
        output = Mat[DType.uint8](rows, w, 3, False)
        status = tj.call["tj3Decompress8", Int32](h, bytes.unsafe_ptr(), len(bytes), output.ptr(), Int32(w * 3), Int32(1))
    tj.call["tj3Destroy", NoneType](h)
    _ = len(bytes)
    if status != 0:
        raise Error("TurboJPEG header or decode")
    return output^


def parity(tj: OwnedDLHandle, bytes: List[UInt8]) raises -> Int:
    var got = decode_baseline_jpeg(bytes)
    var want = oracle(tj, bytes)
    if not got.same_shape(want):
        raise Error("shape differs from TurboJPEG")
    var high = 0
    var n = 0
    for i in range(got.size()):
        var delta = abs(Int(got.data[i]) - Int(want.data[i]))
        if delta > high:
            high, n = delta, i
    if high != 0:
        raise Error(String("max_abs=", high, " at x=", n // 3 % got.cols, " y=", n // 3 // got.cols,
                           " BGR channel=", n % 3, " got=", Int(got.data[n]), " oracle=", Int(want.data[n])))
    return high


def timed[use_tj: Bool](tj: OwnedDLHandle, bytes: List[UInt8]) raises -> Int:
    var t = perf_counter_ns()
    var image: Mat[DType.uint8]
    comptime if use_tj:
        image = oracle(tj, bytes)
    else:
        image = decode_baseline_jpeg(bytes)
    var elapsed = Int(perf_counter_ns() - t)
    if image.rows != 3456 or image.cols != 6144 or image.size() != 6144 * 3456 * 3:
        raise Error("expected the 6144x3456 benchmark image")
    return elapsed


def speed(tj: OwnedDLHandle, bytes: List[UInt8]) raises:
    _ = parity(tj, bytes)
    var native = List[Int]()
    var turbo = List[Int]()
    for i in range(9):
        if i & 1:
            native.append(timed[False](tj, bytes))
            turbo.append(timed[True](tj, bytes))
        else:
            turbo.append(timed[True](tj, bytes))
            native.append(timed[False](tj, bytes))
    sort(native)
    sort(turbo)
    var ratio = Float64(native[4]) / Float64(turbo[4])
    print("baseline_ms=", Float64(native[4]) / 1e6, " turbo_ms=", Float64(turbo[4]) / 1e6, " ratio=", ratio, sep="")
    if ratio > 1.2:
        raise Error("decode exceeds 1.2x TurboJPEG (median of 9, one core)")


def rejection(bytes: List[UInt8], prefix: String) raises:
    try:
        _ = decode_baseline_jpeg(bytes)
    except e:
        if not String(e).startswith(prefix):
            raise Error("expected " + prefix + ", got " + String(e))
        return
    raise Error("decoder accepted the input")


def main() raises:
    var args = argv()
    if len(args) < 3:
        raise Error("usage: jpeg_baseline parity|speed|corrupt|unsupported|rss-native|rss-turbo FILE...")
    var mode = String(args[1])
    for i in range(2, len(args)):
        var path = String(args[i])
        try:
            var bytes = read_jpeg(path)
            if mode == "corrupt":
                rejection(bytes, "jpeg:")
            elif mode == "unsupported":
                rejection(bytes, "unsupported:")
            else:
                var tj = OwnedDLHandle("libturbojpeg.so.0", RTLD.NOW | 0x8)
                if mode == "parity":
                    print("PASS parity", path, "max_abs=", parity(tj, bytes))
                elif mode == "speed":
                    speed(tj, bytes)
                elif mode == "rss-native":
                    print("native_ns=", timed[False](tj, bytes))
                elif mode == "rss-turbo":
                    print("turbo_ns=", timed[True](tj, bytes))
                else:
                    raise Error("unknown check")
        except e:
            raise Error(String("FAIL ", mode, ": ", String(e)))
