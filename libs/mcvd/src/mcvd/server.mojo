"""mcvd server, serialized proof (plan R2a, 3.2): one process, one compute owner. It takes `mcvd.lock` (flock) before it binds, listens on
`DIR/mcvd.sock` (DIR mode 0700), multiplexes the peers with poll(2) and runs each whole request to its reply before it looks at the next one.
Ops: `ping`; `run` (any registered GpuNet graph: named float or int32 tensors in, every graph output out); `siglip_text` (ids n x 64 to
text_embeds n x 768). Failures answer a status and never end the process: bad_frame (the peer is then dropped), unknown_op, unknown_model,
timeout (a frame not whole 5 s after its first byte), internal. Not here yet (R2b): busy and the queue of 32, deadlines, residency budget and
eviction, model keys with a sha256 prefix, SIGTERM drain."""
from std.collections import Dict
from std.ffi import external_call
from std.sys import exit
from std.time import monotonic
from max.gpu.host import DeviceContext
from msgpack import Encoder, parse, ARR, STR
from posix import getpid, unix_listen, accept, recv, send_all, close, PollSet, POLLIN, POLLHUP, POLLERR, cstr, errno
from gpunet.gpu.net import GpuNet
from gpunet.nn import Arr
from gpunet.onnx import Model
from gpunet.text import SiglipText
from mcvd.proto import *

comptime KIND_RUN = 0
comptime KIND_TEXT = 1
comptime MAX_TEXTS = 256


struct Registry(Movable):
    var names: Dict[String, Int]  # name -> kind * 1000 + index
    var nets: List[GpuNet]
    var texts: List[SiglipText]

    def __init__(out self):
        self.names = Dict[String, Int]()
        self.nets = List[GpuNet]()
        self.texts = List[SiglipText]()

    def add(mut self, ctx: DeviceContext, spec: String) raises:
        """spec = NAME=KIND:ARM:PATH, KIND run or text, ARM 16 (fp16 weights) or 32."""
        var eq = spec.find("=")
        var parts = String(spec[byte = eq + 1 :]).split(":", maxsplit=2)
        if eq < 0 or len(parts) != 3:
            raise Error("FAIL usage: model spec " + spec + " is not NAME=KIND:ARM:PATH")
        var name = String(spec[byte=:eq])
        var fp16 = String(parts[1]) == "16"
        var m = Model(String(parts[2]))
        if String(parts[0]) == "run":
            self.nets.append(GpuNet(ctx, m, fp16))
            self.names[name] = KIND_RUN * 1000 + len(self.nets) - 1
        elif String(parts[0]) == "text":
            self.texts.append(SiglipText(ctx, m, fp16))
            self.names[name] = KIND_TEXT * 1000 + len(self.texts) - 1
        else:
            raise Error("FAIL usage: model kind " + String(parts[0]) + " is not run or text")
        print("mcvd: model", name, "kind", String(parts[0]), "arm", "16" if fp16 else "32", flush=True)


def put_tensor(mut e: Encoder, mut body: List[UInt8], name: String, shape: List[Int], d: List[Float32]) raises:
    e.map(2)
    e.str("name")
    e.str(name)
    e.str("shape")
    e.array(len(shape))
    for s in shape:
        e.int(s)
    mcv_put(body, len(d) // shape[len(shape) - 1], shape[len(shape) - 1], DT_F32, Span[UInt8](unsafe_ptr=d.unsafe_ptr().bitcast[UInt8](), length=len(d) * 4))


def dispatch(mut reg: Registry, f: Frame, mut rbody: List[UInt8]) raises -> List[UInt8]:
    """The reply header of request `f`; `rbody` receives the reply body. Raises `STATUS: why` for a refusal."""
    var doc = parse(f.hdr)
    var oi = field(doc, 0, "op")
    if oi < 0 or doc.nodes[oi].kind != STR:
        raise bad("header has no op")
    var op = String(doc.str(oi))
    if op == "ping":
        return reply_header(STATUS_OK)
    if op != "run" and op != "siglip_text":
        raise Error(STATUS_UNKNOWN_OP + ": " + op)
    var mi = field(doc, 0, "model")
    if mi < 0 or doc.nodes[mi].kind != STR:
        raise bad("header has no model")
    var model = String(doc.str(mi))
    if model not in reg.names:
        raise Error(STATUS_UNKNOWN_MODEL + ": " + model)
    var slot = reg.names[model]
    var off = 0
    var e = Encoder()
    e.map(2)
    e.str("status")
    e.str(STATUS_OK)
    e.str("outputs")
    if op == "siglip_text":
        if slot // 1000 != KIND_TEXT:
            raise Error(STATUS_UNKNOWN_MODEL + ": " + model + " is not a text model")
        var t = read_tensor(f.body, off)
        var n = len(t) // 64
        if n * 64 != len(t) or n > MAX_TEXTS or off != len(f.body):
            raise bad("siglip_text wants one record of n x 64 ids, n up to " + String(MAX_TEXTS))
        var ids = List[Int](capacity=len(t))
        for x in t:
            ids.append(Int(x))
        var h = List[Float32]()
        var p = List[Float32]()
        var emb = List[Float32]()
        reg.texts[slot % 1000].forward(ids, 0, n, h, p, emb)
        e.array(1)
        put_tensor(e, rbody, "text_embeds", [n, 768], emb)
        return e.buf.copy()
    if slot // 1000 != KIND_RUN:
        raise Error(STATUS_UNKNOWN_MODEL + ": " + model + " is not a run model")
    var ii = field(doc, 0, "inputs")
    if ii < 0 or doc.nodes[ii].kind != ARR:
        raise bad("run wants an inputs array")
    var feeds = Dict[String, Arr]()
    var k = ii + 1
    for _ in range(Int(doc.nodes[ii].n)):
        var ni = field(doc, k, "name")
        var si = field(doc, k, "shape")
        if ni < 0 or si < 0 or doc.nodes[si].kind != ARR:
            raise bad("input needs name and shape")
        var shape = List[Int]()
        var numel = 1
        for q in range(Int(doc.nodes[si].n)):
            shape.append(doc.int(si + 1 + q))
            numel *= shape[q]
        var d = read_tensor(f.body, off)
        if len(d) != numel:
            raise bad("input " + String(doc.str(ni)) + ": shape holds " + String(numel) + " values, record " + String(len(d)))
        feeds[String(doc.str(ni))] = Arr(shape^, d^)
        k += Int(doc.nodes[k].size)
    if off != len(f.body):
        raise bad("bytes after the last input record")
    ref net = reg.nets[slot % 1000]
    var outs = net.run(feeds^)
    e.array(len(net.outputs))
    for name in net.outputs:
        ref o = outs[name]
        put_tensor(e, rbody, name, o.shape, o.d)
    return e.buf.copy()


struct Peer(Movable):
    var fd: Int32
    var fb: FrameBuf
    var dead: Bool

    def __init__(out self, fd: Int32):
        self.fd = fd
        self.fb = FrameBuf()
        self.dead = False


def _ms() -> Int:
    return Int(monotonic() // 1_000_000)


def _send(fd: Int32, id: UInt64, hdr: List[UInt8], body: List[UInt8]) -> Bool:
    return send_all(fd, Span(pack(KIND_REP, id, hdr, body)))


def _status_of(msg: String) -> String:
    var c = msg.find(":")
    var s = String(msg[byte=:c]) if c > 0 else String("")
    if s == STATUS_BAD_FRAME or s == STATUS_UNKNOWN_OP or s == STATUS_UNKNOWN_MODEL or s == STATUS_BUSY or s == STATUS_OOM:
        return s
    return STATUS_INTERNAL


def take_lock(dir: String) raises -> Int32:
    """Create DIR (0700) and flock DIR/mcvd.lock without waiting; a second instance exits 3 before it touches the socket."""
    var d = cstr(dir)
    _ = external_call["mkdir", Int32](d.unsafe_ptr(), Int32(0o700))
    _ = external_call["chmod", Int32](d.unsafe_ptr(), Int32(0o700))
    var p = cstr(dir + "/mcvd.lock")
    var fd = external_call["open", Int32](p.unsafe_ptr(), Int32(0o2000102), Int32(0o600))
    if fd < 0:
        raise Error("FAIL lock: cannot open " + dir + "/mcvd.lock")
    if external_call["flock", Int32](fd, Int32(6)) != 0:
        print("mcvd: another instance holds " + dir + "/mcvd.lock", flush=True)
        exit(3)
    _ = (d[0], p[0])
    return fd


def serve(dir: String, specs: List[String]) raises:
    var lock = take_lock(dir)
    var ctx = DeviceContext()
    var reg = Registry()
    for s in specs:
        reg.add(ctx, s)
    var lfd = unix_listen(dir + "/mcvd.sock")
    print("mcvd: pid", getpid(), flush=True)
    print("mcvd: ready", dir + "/mcvd.sock", flush=True)
    var peers = List[Peer]()
    while True:
        var ps = PollSet()
        _ = ps.add(lfd)
        for j in range(len(peers)):
            _ = ps.add(peers[j].fd)
        _ = ps.wait(200)
        var n0 = len(peers)
        if ps.revents(0) & POLLIN != 0:
            while True:
                var c = accept(lfd)
                if c < 0:
                    break
                peers.append(Peer(c))
        var now = _ms()
        for j in range(n0):
            ref p = peers[j]
            var rev = ps.revents(j + 1)
            if rev & (POLLIN | POLLHUP | POLLERR) != 0:
                var got = False
                while True:
                    var r = recv(p.fd, p.fb.buf)
                    if r > 0:
                        got = True
                    else:
                        if r == 0 or (not got and rev & POLLIN == 0):
                            p.dead = True
                        break
            var f = Frame()
            while not p.dead:
                var s = p.fb.next(f, now)
                if s == 0:
                    break
                if s < 0:
                    print("mcvd: bad frame:", p.fb.fault, flush=True)
                    _ = _send(p.fd, 0, reply_header(STATUS_BAD_FRAME, p.fb.fault), List[UInt8]())
                    p.dead = True
                    break
                var rb = List[UInt8]()
                var rh = List[UInt8]()
                try:
                    if f.kind != KIND_REQ:
                        raise bad("not a request")
                    rh = dispatch(reg, f, rb)
                except e:
                    var m = String(e)
                    var st = _status_of(m)
                    rb.clear()
                    rh = reply_header(st, m)
                    if st == STATUS_BAD_FRAME:
                        p.dead = True
                if not _send(p.fd, f.id, rh, rb):
                    p.dead = True
            if not p.dead and p.fb.first_ms >= 0 and now - p.fb.first_ms > READ_TIMEOUT_MS:
                _ = _send(p.fd, 0, reply_header(STATUS_TIMEOUT, "frame not whole within 5 s"), List[UInt8]())
                p.dead = True
        for i in range(len(peers) - 1, -1, -1):
            if peers[i].dead:
                close(peers[i].fd)
                _ = peers.pop(i)
    _ = lock
