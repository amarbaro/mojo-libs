# Throughput of zstd on one file (argument 2 is the level, 3 when absent): best of 5 compress and best of 5
# decompress, one round-trip check first. Prints 'c_mbps=<best> d_mbps=<best> size=<input bytes> csize=<compressed bytes>' (MB = 1e6 bytes). Modelled on tests/bench.mojo.
from std.sys import argv
from std.time import perf_counter_ns
import zstd


def main() raises:
    var raw: List[UInt8]
    with open(String(argv()[1]), "r") as f:
        raw = f.read_bytes()
    var size = len(raw)
    var level = Int(argv()[2]) if len(argv()) > 2 else 3
    var c = zstd.compress(raw, level)
    var d = zstd.decompress(c)
    if d != raw:
        raise Error("bench31: zstd round trip differs")
    var best_c = 0
    var best_d = 0
    for i in range(5):
        var t0 = Int(perf_counter_ns())
        _ = zstd.compress(raw, level)
        var dt = Int(perf_counter_ns()) - t0
        if i == 0 or dt < best_c:
            best_c = dt
    var out = List[UInt8]()  # reused, as zstd -b reuses its buffer
    for i in range(5):
        var t0 = Int(perf_counter_ns())
        zstd.decompress_into(c, out)
        var dt = Int(perf_counter_ns()) - t0
        if len(out) != size:
            raise Error("bench31: decompress length differs")
        if i == 0 or dt < best_d:
            best_d = dt
    var c_mbps = Float64(size) * 1000.0 / Float64(best_c)
    var d_mbps = Float64(size) * 1000.0 / Float64(best_d)
    print("c_mbps=" + String(c_mbps) + " d_mbps=" + String(d_mbps) + " size=" + String(size) + " csize=" + String(len(c)))
