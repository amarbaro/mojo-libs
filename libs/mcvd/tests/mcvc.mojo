"""mcvc MODE SOCK ...: test client of mcvd. Modes with replies: ping; text MODEL IDS OUT BATCH [FIRST COUNT]; run MODEL INPUT BLOBLIST OUTDIR;
and canned faults, each printing `status=<status>` or `closed`: badop, badmodel, badmagic, big, short, drop."""
from std.sys import argv
from msgpack import Encoder, parse
from posix import unix_connect, send_all, close, recv, PollSet, POLLIN
from mcvd.client import call, read_reply
from mcvd.proto import *


def req(op: String, model: String = "", input: String = "", shape: List[Int] = List[Int]()) raises -> List[UInt8]:
    var e = Encoder()
    var n = 1 + (1 if model.byte_length() > 0 else 0) + (1 if input.byte_length() > 0 else 0)
    e.map(n)
    e.str("op")
    e.str(op)
    if model.byte_length() > 0:
        e.str("model")
        e.str(model)
    if input.byte_length() > 0:
        e.str("inputs")
        e.array(1)
        e.map(2)
        e.str("name")
        e.str(input)
        e.str("shape")
        e.array(len(shape))
        for s in shape:
            e.int(s)
    return e.buf.copy()


def status_of(f: Frame) raises -> String:
    var d = parse(f.hdr)
    return String(d.str(field(d, 0, "status")))


def outcome(fd: Int32, wait_ms: Int) raises:
    try:
        var f = read_reply(fd, wait_ms)
        print("status=" + status_of(f))
    except e:
        print("closed" if String(e) == "closed" else String(e))


def raw_prefix(kind: UInt8, id: UInt64, hl: Int, bl: Int, magic: String = "MCVD") -> List[UInt8]:
    var o = pack(kind, id, List[UInt8](), List[UInt8]())
    for i in range(4):
        o[i] = magic.as_bytes()[i]
    for i in range(4):
        o[16 + i] = UInt8((hl >> (8 * i)) & 0xFF)
        o[20 + i] = UInt8((bl >> (8 * i)) & 0xFF)
    return o^


def put(path: String, v: List[Float32], append: Bool = False) raises:
    with open(path, "a" if append else "w") as f:
        f.write_bytes(Span[UInt8](unsafe_ptr=v.unsafe_ptr().bitcast[UInt8](), length=len(v) * 4))


def main() raises:
    var a = argv()
    var mode = String(a[1])
    var fd = unix_connect(String(a[2]))
    if mode == "ping":
        print("status=" + status_of(call(fd, 1, req("ping"), List[UInt8]())))
    elif mode == "badop":
        print("status=" + status_of(call(fd, 2, req("frobnicate"), List[UInt8]())))
    elif mode == "badmodel":
        print("status=" + status_of(call(fd, 3, req("siglip_text", "nope"), List[UInt8]())))
    elif mode == "badmagic":
        _ = send_all(fd, Span(raw_prefix(KIND_REQ, 4, 0, 0, "XXXX")))
        outcome(fd, 5000)
    elif mode == "big":  # a valid prefix that promises 2 GiB: refused from the prefix, no payload byte is read or stored
        _ = send_all(fd, Span(raw_prefix(KIND_REQ, 5, 10, 0x7FFFFFFF)))
        outcome(fd, 5000)
    elif mode == "short":  # a frame that stops after 5 of its 40 payload bytes and stays silent: status timeout after 5 s
        var p = raw_prefix(KIND_REQ, 6, 40, 0)
        for i in range(5):
            p.append(1)
        _ = send_all(fd, Span(p))
        outcome(fd, 12000)
    elif mode == "drop":  # promises 100 body bytes, sends 10, hangs up
        var p = raw_prefix(KIND_REQ, 7, 0, 100)
        for i in range(10):
            p.append(2)
        _ = send_all(fd, Span(p))
        print("dropped")
    elif mode == "text":  # text SOCK MODEL IDS OUT BATCH [FIRST COUNT]
        var ids = List[Int]()
        for line in open(String(a[4]), "r").read().split("\n"):
            for t in line.split(" "):
                if t.byte_length() > 0:
                    ids.append(Int(String(t)))
        var n = len(ids) // 64
        var first = Int(String(a[7])) if len(a) > 7 else 0
        var count = Int(String(a[8])) if len(a) > 8 else n - first
        var nb = Int(String(a[6]))
        var out = String(a[5])
        var all = List[Float32]()
        var i = first
        while i < first + count:
            var b = min(nb, first + count - i)
            var body = List[UInt8]()
            var raw = List[Int32](capacity=b * 64)
            for q in range(b * 64):
                raw.append(Int32(ids[i * 64 + q]))
            mcv_put(body, b, 64, DT_I32, Span[UInt8](unsafe_ptr=raw.unsafe_ptr().bitcast[UInt8](), length=len(raw) * 4))
            var rep = call(fd, UInt64(100 + i), req("siglip_text", String(a[3])), body)
            if status_of(rep) != "ok":
                raise Error("FAIL text: status " + status_of(rep))
            var off = 0
            all.extend(read_tensor(rep.body, off))
            i += b
        put(out, all)
        print("ok text:", count, "texts")
    elif mode == "run":  # run SOCK MODEL INPUT BLOBLIST OUTDIR
        var idx = 0
        for path in open(String(a[5]), "r").read().split("\n"):
            if path.byte_length() == 0:
                continue
            var raw = open(String(path), "r").read_bytes()
            var body = List[UInt8]()
            mcv_put(body, 3 * 640, 640, DT_F32, Span(raw))
            var rep = call(fd, UInt64(200 + idx), req("run", String(a[3]), String(a[4]), [1, 3, 640, 640]), body)
            if status_of(rep) != "ok":
                raise Error("FAIL run: status " + status_of(rep))
            var d = parse(rep.hdr)
            var oi = field(d, 0, "outputs")
            var off = 0
            var cat = List[Float32]()
            for _ in range(Int(d.nodes[oi].n)):
                cat.extend(read_tensor(rep.body, off))
            var tag = String(idx)
            while tag.byte_length() < 2:
                tag = "0" + tag
            put(String(a[6]) + "/" + tag + ".raw.f32", cat)
            idx += 1
        print("ok run:", idx, "images")
    else:
        raise Error("FAIL usage: unknown mode " + mode)
    close(fd)
