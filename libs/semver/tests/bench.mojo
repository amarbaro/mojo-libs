# Parse + compare throughput over the random corpus, ns per op.
from std.time import perf_counter_ns
from semver import parse


def main() raises:
    var vs = List[String]()
    with open("tests/data/random.txt", "r") as f:
        for l in f.read().split("\n"):
            if l:
                vs.append(String(l))
    comptime R = 200
    var t0 = perf_counter_ns()
    var acc = 0
    for _ in range(R):
        for s in vs:
            acc += parse(s).patch
    var ns_parse = Float64(perf_counter_ns() - t0) / Float64(R * len(vs))
    var ps = List[type_of(parse(vs[0]))]()
    for s in vs:
        ps.append(parse(s))
    t0 = perf_counter_ns()
    for _ in range(R):
        for i in range(len(ps) - 1):
            acc += ps[i].compare(ps[i + 1])
    var ns_cmp = Float64(perf_counter_ns() - t0) / Float64(R * (len(ps) - 1))
    print("parse ns", ns_parse, " compare ns", ns_cmp, " (", acc, ")")
