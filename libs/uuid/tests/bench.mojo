from uuid import UUID, uuid4
from std.time import perf_counter_ns
from std.sys import size_of

def main() raises:
    var text = String("919108f7-52d1-4320-9bac-f847db4148a8")
    var value = UUID(text)
    var checksum: UInt128 = 0
    var start = perf_counter_ns()
    for i in range(10000):
        checksum ^= UUID(text).int()
    print("parse ns/op", (perf_counter_ns() - start) / 10000)
    start = perf_counter_ns()
    var count = 0
    for i in range(10000):
        count += value.__str__().byte_length()
    print("str ns/op", (perf_counter_ns() - start) / 10000)
    start = perf_counter_ns()
    for i in range(10000):
        checksum ^= uuid4().int()
    print("uuid4 ns/op", (perf_counter_ns() - start) / 10000)
    print("UUID bytes", size_of[UUID](), "checksum", checksum, count)
