# Shared stdin plumbing for row drivers: one stdin row in, one JSON line out.
# input() in Mojo 1.2 drops everything after the first line, so read fd 0 directly.
from std.ffi import external_call
from std.memory import alloc, Layout


def read_rows() raises -> List[String]:
    var buf = List[UInt8]()
    var chunk = alloc(Layout[UInt8](count=65536)).unsafe_leak()
    while True:
        var n = external_call["read", Int](Int32(0), chunk, 65536)  # fd type must match the stdlib's own read()
        if n <= 0:
            break
        for i in range(n):
            buf.append(chunk[i])
    chunk.unsafe_free()
    var text = String(unsafe_from_utf8=buf)
    var rows = List[String]()
    for line in text.split("\n"):  # not splitlines(): it also splits at tabs
        if line.byte_length() > 0:
            rows.append(String(line))
    return rows^
