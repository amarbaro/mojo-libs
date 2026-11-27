# Errors are raised, never crash: bad level, corrupt, truncated, empty and trailing input, missing file.
import lz4
import zstd


def raises(name: String, prefix: String, ok: Bool) raises:
    if not ok:
        raise Error("api: ", name, " did not raise ", prefix, "...")


def main() raises:
    var s = ("abc" * 1000).as_bytes()
    var z = zstd.compress(s, 19)
    var l = lz4.compress(s)
    for k in range(len(z)):  # every proper prefix is an error
        try:
            _ = zstd.decompress(Span(z)[:k])
            raise Error("api: zstd prefix ", k, " decoded")
        except e:
            raises("zstd prefix", "zstd: ", String(e).startswith("zstd: "))
    for k in range(len(l)):
        try:
            _ = lz4.decompress(Span(l)[:k])
            raise Error("api: lz4 prefix ", k, " decoded")
        except e:
            raises("lz4 prefix", "lz4: ", String(e).startswith("lz4: "))
    var junk = List[UInt8](length=64, fill=0xA5)
    try:
        _ = zstd.decompress(junk)
        raise Error("api: zstd junk decoded")
    except e:
        raises("zstd junk", "zstd: ", String(e).startswith("zstd: "))
    try:
        _ = zstd.ZstdReader(".work/no/such.zst")
        raise Error("api: missing file opened")
    except e:
        raises("missing file", "zstd: ", String(e).startswith("zstd: "))
    if len(zstd.decompress(zstd.compress(List[UInt8]()))) != 0 or len(lz4.decompress(lz4.compress(List[UInt8]()))) != 0:
        raise Error("api: empty round trip")
    var out = List[UInt8]()  # decompress_into: one buffer through a large, a small, then a corrupt frame
    zstd.decompress_into(z, out)
    var small = zstd.compress("xyz".as_bytes())
    var ok = out == List(s)
    zstd.decompress_into(small, out)
    ok = ok and out == List("xyz".as_bytes())
    try:
        zstd.decompress_into(junk, out)
    except:
        ok = ok and len(out) == 0
    if not ok:
        raise Error("api: decompress_into reuse")
    # a frame's capacity stays near its size, not the worst-case reserve of the input size
    var rep = List[UInt8](("one repeated sentence. " * 200000).as_bytes())
    var frame = zstd.compress(rep, 3)
    if frame.capacity() > len(frame) + len(frame) // 4 + 4096:
        raise Error("api: compress capacity ", frame.capacity(), " for a ", len(frame), " byte frame")
    # ZstdReader: the 4 checksum bytes may sit past the end of its 256 KiB input buffer
    var rnd = List[UInt8](length=262140, fill=0)
    var x: UInt64 = 88172645463325252
    for i in range(len(rnd)):
        x ^= x << 13; x ^= x >> 7; x ^= x << 17
        rnd[i] = UInt8(x & 255)
    for cut in range(262120, 262136):
        var c = zstd.compress(Span(rnd)[:cut], 3)
        with open(".work/api-split.zst", "w") as f:
            f.write_bytes(c)
        var r = zstd.ZstdReader(".work/api-split.zst")
        var buf = List[UInt8](length=1 << 16, fill=0)
        var got = 0
        while True:
            var k = r.read(buf)
            if k == 0:
                break
            got += k
        if got != cut:
            raise Error("api: ZstdReader got ", got, " of ", cut, " bytes (frame ", len(c), ")")
    print("api: ok")
