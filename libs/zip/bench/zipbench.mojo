# Hot paths of mojo-zip, same jobs and fixtures as tools/bench_ref.py. Usage: zipbench many|stored|stored_view|deflate
from std.sys import argv
from std.time import perf_counter_ns
from std.benchmark import keep
from zipfile import ZipReader
from deflate import crc32


def main() raises:
    var which = String(argv()[1])
    var t0 = perf_counter_ns()
    var check = String()
    if which == "many":
        var z = ZipReader.open(".work/bench/many.zip")
        var total = 0
        for i in range(len(z.infolist())):
            total += z.infolist()[i].file_size
        keep(total)
        check = "entries " + String(len(z.namelist())) + " bytes " + String(total)
    elif which == "stored_view":
        var z = ZipReader.open(".work/bench/big_stored.zip")
        var v = z.read_view("big.bin")
        check = "bytes " + String(len(v)) + " crc " + String(crc32(v))
    else:
        var z = ZipReader.open(".work/bench/big_" + which + ".zip")
        var data = z.read("big.bin")
        check = "bytes " + String(len(data)) + " crc " + String(crc32(Span(data)))
    var t1 = perf_counter_ns()
    print("mojo", which, "ms", (t1 - t0) // 1_000_000, check)
