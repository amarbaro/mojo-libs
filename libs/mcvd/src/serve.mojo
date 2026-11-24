"""mcvd DIR NAME=KIND:ARM:PATH...: the serialized daemon (see mcvd/server.mojo). Run it under `gpu-wait run --shared --vram N --label mcvd --`."""
from std.sys import argv
from mcvd.server import serve


def main() raises:
    var a = argv()
    if len(a) < 2:
        raise Error("usage: mcvd DIR [NAME=KIND:ARM:PATH ...]  (KIND run or text, ARM 16 or 32)")
    var specs = List[String]()
    for i in range(2, len(a)):
        specs.append(String(a[i]))
    serve(String(a[1]), specs)
