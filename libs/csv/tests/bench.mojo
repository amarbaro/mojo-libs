"""Materialize the same roughly 50 MB CSV as tools/bench_ref.py."""
from csv import Reader, Dialect, CsvField
from std.time import perf_counter_ns
from std.sys import size_of
from std.os import getenv


def main() raises:
    var template = "alpha,beta,\"gamma,delta\",\"say \"\"hi\"\"\",012345678901234567890123456789\r\n"
    var records = Int(getenv("BENCH_BYTES", "50000000")) // template.byte_length()
    var input = List[UInt8](capacity=records * template.byte_length())
    for _ in range(records):
        for c in template.as_bytes():
            input.append(c)
    var reader = Reader(Dialect.excel())
    var started = perf_counter_ns()
    var rows = reader.read_all(Span(input))
    var elapsed = Float64(perf_counter_ns() - started) / 1e9
    if len(rows) != records or len(rows[records - 1]) != 5 or len(rows[0][2].data) != 11 or len(rows[records - 1][3].data) != 8:
        raise Error("benchmark result mismatch")
    print("Mojo bytes", len(input), "rows", len(rows), "seconds", elapsed, "MB/s", Float64(len(input)) / elapsed / 1e6)
    print("rows:", len(rows))
    print("parse seconds:", elapsed)
    print("parse MB/s:", Float64(len(input)) / elapsed / 1e6)
    print("sizes Dialect", size_of[Dialect](), "Reader", size_of[Reader](), "CsvField", size_of[CsvField]())
