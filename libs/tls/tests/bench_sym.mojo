"""Throughput of the lane 1 AEADs: 16 KiB records sealed in place, one resident process. Run: bench_sym [MS per row]."""
from std.sys import argv
from std.time import perf_counter_ns
from tls.sym.aead import Aead
from tls.sym.gcm import AesGcm


def rate[A: Aead](name: String, a: A, ms: Int) raises:
    var nonce = List[UInt8](length=12, fill=7)
    var aad = List[UInt8](length=13, fill=1)
    var buf = List[UInt8](length=16384, fill=3)
    a.seal(nonce, aad, buf)
    buf.shrink(16384)
    var best = Int.MAX
    var t_end = perf_counter_ns() + ms * 1_000_000
    while perf_counter_ns() < t_end:
        var t0 = perf_counter_ns()
        for _ in range(50):
            a.seal(nonce, aad, buf)
            buf.shrink(16384)
        best = min(best, Int(perf_counter_ns() - t0))
    print(name, "16 KiB seal:", Float64(50 * 16384) / Float64(best), "GB/s (best of batches of 50)")


def main() raises:
    var ms = Int(argv()[1]) if len(argv()) > 1 else 300
    rate("aes-128-gcm", AesGcm(List[UInt8](length=16, fill=9)), ms)
    rate("aes-256-gcm", AesGcm(List[UInt8](length=32, fill=9)), ms)
