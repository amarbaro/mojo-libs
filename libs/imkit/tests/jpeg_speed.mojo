"""JPEG speed and output hash for imkit (CPU), against libjpeg-turbo's djpeg output. tests/jpeg_speed.sh runs both.
usage: jpeg_speed FILE.jpg...          decode with imkit: per-stage ms and FNV-1a of the RGB bytes, then MEAN
       jpeg_speed hash-ppm FILE.ppm... FNV-1a of each PPM's pixel data (header stripped)"""
from std.sys import argv
from std.time import perf_counter_ns
from imkit.jpeg import Jpeg

comptime FNV_OFFSET: UInt64 = 14695981039346656037
comptime FNV_PRIME: UInt64 = 1099511628211


def load(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def fnv1a(p: Span[UInt8, _], start: Int) -> UInt64:
    var h = FNV_OFFSET
    for i in range(start, len(p)):
        h = (h ^ UInt64(p[i])) * FNV_PRIME
    return h


def is_space(c: UInt8) -> Bool:
    return c == 32 or c == 10 or c == 13 or c == 9


def ppm_data(b: List[UInt8]) raises -> Int:
    """Offset of the pixel data: magic P6, then width, height, maxval, then one whitespace byte."""
    if len(b) < 2 or b[0] != 80 or b[1] != 54:
        raise Error("not a P6 PPM")
    var pos = 2
    for _ in range(3):
        while pos < len(b) and is_space(b[pos]):
            pos += 1
        while pos < len(b) and not is_space(b[pos]):
            pos += 1
    return pos + 1


def hex16(v: UInt64) -> String:
    var digits = "0123456789abcdef"
    var s = String()
    for i in range(15, -1, -1):
        var d = Int((v >> UInt64(4 * i)) & 15)
        s += String(digits[byte=d : d + 1])
    return s


def ms(ns: Int) -> String:
    var t = ns // 100_000  # tenths of a millisecond
    return String(t // 10) + "." + String(t % 10)


def main() raises:
    var a = argv()
    if len(a) < 2:
        raise Error("usage: jpeg_speed FILE.jpg... | jpeg_speed hash-ppm FILE.ppm...")
    if a[1] == "hash-ppm":
        for i in range(2, len(a)):
            var b = load(String(a[i]))
            print(hex16(fnv1a(Span(b), ppm_data(b))))
        return
    var n = 0
    var s_parse = 0
    var s_idct = 0
    var s_rgb = 0
    for k in range(1, len(a)):
        var path = String(a[k])
        var d = load(path)
        var t0 = perf_counter_ns()
        var j = Jpeg(Span(d))
        j.parse()
        var t1 = perf_counter_ns()
        j.idct()
        var t2 = perf_counter_ns()
        var px = j.rgb()
        var t3 = perf_counter_ns()
        var p = Int(t1 - t0)
        var q = Int(t2 - t1)
        var r = Int(t3 - t2)
        s_parse += p
        s_idct += q
        s_rgb += r
        n += 1
        print(path, ms(p), ms(q), ms(r), ms(p + q + r), "fnv=" + hex16(fnv1a(Span(px), 0)))
    if n == 0:
        raise Error("no input files")
    var m = s_parse + s_idct + s_rgb
    print("MEAN", ms(s_parse // n), ms(s_idct // n), ms(s_rgb // n), ms(m // n), "n", n)
