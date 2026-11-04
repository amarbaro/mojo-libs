# Write a file through a mapping, then read it back with no copy.
from mmap import MappedFile, create, SEQUENTIAL


def main() raises:
    var w = create("mojo-mmap-quickstart.bin", 1 << 20)
    var b = w.mut_bytes()
    for i in range(len(b)):
        b[i] = UInt8(i & 255)
    w.flush()
    _ = w^

    var m = MappedFile("mojo-mmap-quickstart.bin")
    m.advise(SEQUENTIAL)
    var total = 0
    for v in m.bytes():
        total += Int(v)
    print(len(m), "bytes, sum", total)
