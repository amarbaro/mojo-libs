# Hot path: Struct.unpack_from over 1M records of "<hIqd" (22 bytes), same work as tools/bench_ref.py.
from std.time import perf_counter_ns
from std.benchmark import keep
from pystruct import Struct, Bytes, Value


def main() raises:
    comptime N = 1_000_000
    var s = Struct("<hIqd")
    var buf = Bytes(length=N * s.size, fill=0)
    for i in range(len(buf)):
        buf[i] = UInt8((i * 131 + 7) & 0x7F)
    var t0 = perf_counter_ns()
    var total = Int128(0)
    var f = 0.0
    var v = List[Value](capacity=4)
    for r in range(N):
        s.unpack_from_into(Span(buf), r * s.size, v)
        total += v[0].int + v[1].int + v[2].int
        f += v[3].re
    var t1 = perf_counter_ns()
    var p = Bytes(length=s.size, fill=0)
    var w: List[Value] = [Int128(0), Int128(0), Int128(0), 0.0]
    for r in range(N):
        w[0].int = Int128(r & 0x7FFF)
        w[1].int = Int128(r)
        w[2].int = Int128(r) * 3
        w[3].re = Float64(r)
        s.pack_into(p, 0, w)
    var t2 = perf_counter_ns()
    keep(total)
    keep(f)
    keep(p[3])
    print("mojo unpack_from_ns_per_record", (t1 - t0) // N, "pack_into_ns_per_record", (t2 - t1) // N, "check", total)
