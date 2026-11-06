from base64 import b64encode, b64decode
from std.time import perf_counter_ns

def main() raises:
    for n in [1024, 67108864]:
        var data = List[Byte](length=n, fill=UInt8(97))
        var encoded = b64encode(data)
        var iterations = 10000 if n == 1024 else 3
        var checksum = 0
        var start = perf_counter_ns()
        for i in range(iterations):
            var result = b64encode(data)
            checksum += len(result)
        var elapsed = Float64(perf_counter_ns() - start)
        print("encode bytes", n, "iterations", iterations, "GB/s", Float64(n * iterations) / elapsed)
        start = perf_counter_ns()
        for i in range(iterations):
            var result = b64decode(encoded)
            checksum += len(result)
        elapsed = Float64(perf_counter_ns() - start)
        print("decode bytes", n, "iterations", iterations, "GB/s", Float64(n * iterations) / elapsed)
        print("checksum", checksum)
