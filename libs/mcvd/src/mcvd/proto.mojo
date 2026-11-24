"""mcvd wire protocol v1 (plan 3.2). One frame: a 24-byte prefix, a msgpack header, a raw body.

  bytes 0..3   magic "MCVD"      4 version (1)      5 kind (0 request, 1 reply)      6..7 reserved, zero
  bytes 8..15  request id u64    16..19 header length u32    20..23 body length u32      (all integers little-endian)

The header is one msgpack map, the body a run of `.mcv` records (16 bytes "MCV1", u32 rows, u32 cols, u16 ch, u16 dtype code; then the raw
little-endian data), one per tensor in header order. The frame's payload (header + body) is bounded at 64 MiB, the header at 64 KiB; both
are checked from the prefix alone, before any payload byte is stored. A reply header carries `status`, one of the STATUS_* strings."""
from std.collections import Dict
from std.memory import bitcast
from msgpack import Encoder, Doc, parse, MAP, STR

comptime VERSION: UInt8 = 1
comptime KIND_REQ: UInt8 = 0
comptime KIND_REP: UInt8 = 1
comptime PREFIX = 24
comptime MAX_PAYLOAD = 64 * 1024 * 1024
comptime MAX_HDR = 64 * 1024
comptime READ_TIMEOUT_MS = 5000  # one frame must arrive whole within this, from its first byte

comptime STATUS_OK = "ok"
comptime STATUS_BAD_FRAME = "bad_frame"
comptime STATUS_UNKNOWN_OP = "unknown_op"
comptime STATUS_UNKNOWN_MODEL = "unknown_model"
comptime STATUS_BUSY = "busy"
comptime STATUS_TIMEOUT = "timeout"
comptime STATUS_OOM = "oom"
comptime STATUS_INTERNAL = "internal"

comptime DT_U8 = 0  # the `.mcv` dtype codes of mojocv.mat
comptime DT_F32 = 1
comptime DT_I32 = 2


struct Frame(Movable):
    var kind: UInt8
    var id: UInt64
    var hdr: List[UInt8]
    var body: List[UInt8]

    def __init__(out self):
        self.kind = 0
        self.id = 0
        self.hdr = List[UInt8]()
        self.body = List[UInt8]()


def put_u32(mut b: List[UInt8], v: Int):
    for i in range(4):
        b.append(UInt8((v >> (8 * i)) & 0xFF))


def get_u32(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24


def pack(kind: UInt8, id: UInt64, hdr: List[UInt8], body: List[UInt8]) -> List[UInt8]:
    var o = List[UInt8](capacity=PREFIX + len(hdr) + len(body))
    for c in "MCVD".as_bytes():
        o.append(c)
    o.append(VERSION)
    o.append(kind)
    o.append(0)
    o.append(0)
    for i in range(8):
        o.append(UInt8((id >> UInt64(8 * i)) & 0xFF))
    put_u32(o, len(hdr))
    put_u32(o, len(body))
    o.extend(Span(hdr))
    o.extend(Span(body))
    return o^


struct FrameBuf(Movable):
    """Bytes read from one peer. `next` yields the next whole frame, or says to read more, or names the fault."""

    var buf: List[UInt8]
    var pos: Int
    var first_ms: Int  # monotonic ms of the first byte of the frame being assembled, -1 when none is pending
    var fault: String

    def __init__(out self):
        self.buf = List[UInt8]()
        self.pos = 0
        self.first_ms = -1
        self.fault = ""

    def pending(self) -> Bool:
        return len(self.buf) > self.pos

    def next(mut self, mut f: Frame, now_ms: Int) -> Int:
        """1 = `f` holds a frame, 0 = more bytes needed, -1 = bad frame (see `fault`; the peer is not to be trusted further)."""
        var have = len(self.buf) - self.pos
        if have == 0:
            self.first_ms = -1
            return 0
        if self.first_ms < 0:
            self.first_ms = now_ms
        var p = self.pos
        var n = min(have, 4)
        for i in range(n):  # the magic is judged byte by byte, so a wrong first byte is refused at once
            if self.buf[p + i] != "MCVD".as_bytes()[i]:
                self.fault = "bad magic"
                return -1
        if have < PREFIX:
            return 0
        if self.buf[p + 4] != VERSION:
            self.fault = "unsupported version " + String(Int(self.buf[p + 4]))
            return -1
        if (self.buf[p + 5] != KIND_REQ and self.buf[p + 5] != KIND_REP) or self.buf[p + 6] != 0 or self.buf[p + 7] != 0:
            self.fault = "bad kind or reserved bytes"
            return -1
        var hl = get_u32(self.buf, p + 16)
        var bl = get_u32(self.buf, p + 20)
        if hl > MAX_HDR or hl + bl > MAX_PAYLOAD:
            self.fault = "frame too large: header " + String(hl) + " body " + String(bl)
            return -1
        if have < PREFIX + hl + bl:
            return 0
        f.kind = self.buf[p + 5]
        f.id = UInt64(0)
        for i in range(8):
            f.id |= UInt64(self.buf[p + 8 + i]) << UInt64(8 * i)
        f.hdr = List[UInt8](capacity=hl)
        f.body = List[UInt8](capacity=bl)
        for i in range(hl):
            f.hdr.append(self.buf[p + PREFIX + i])
        for i in range(bl):
            f.body.append(self.buf[p + PREFIX + hl + i])
        self.pos += PREFIX + hl + bl
        if self.pos == len(self.buf):
            self.buf.clear()
            self.pos = 0
            self.first_ms = -1
        else:
            self.first_ms = now_ms
        return 1


def mcv_put(mut body: List[UInt8], rows: Int, cols: Int, dtype: Int, data: Span[UInt8, _]):
    """Append one `.mcv` record (channels 1) holding the raw little-endian bytes `data`."""
    for c in "MCV1".as_bytes():
        body.append(c)
    put_u32(body, rows)
    put_u32(body, cols)
    body.append(1)
    body.append(0)
    body.append(UInt8(dtype))
    body.append(0)
    body.extend(data)


def field(d: Doc, root: Int, key: String) -> Int:
    """Node index of `key`'s value in the map at `root`, or -1."""
    if d.nodes[root].kind != MAP:
        return -1
    var k = root + 1
    for _ in range(Int(d.nodes[root].n)):
        var v = k + Int(d.nodes[k].size)
        if d.nodes[k].kind == STR and d.str(k) == key:
            return v
        k = v + Int(d.nodes[v].size)
    return -1


def reply_header(status: String, msg: String = "") raises -> List[UInt8]:
    var e = Encoder()
    e.map(2 if msg.byte_length() > 0 else 1)
    e.str("status")
    e.str(status)
    if msg.byte_length() > 0:
        e.str("msg")
        e.str(msg)
    return e.buf.copy()


def bad(why: String) -> Error:
    return Error(STATUS_BAD_FRAME + ": " + why)


def read_tensor(body: List[UInt8], mut off: Int) raises -> List[Float32]:
    """The next `.mcv` record of `body` (float32 or int32, one channel) as floats; `off` moves past it."""
    if off + 16 > len(body) or body[off] != 77 or body[off + 1] != 67 or body[off + 2] != 86 or body[off + 3] != 49:
        raise bad("body is not a run of .mcv records")
    var n = get_u32(body, off + 4) * get_u32(body, off + 8) * Int(body[off + 12])
    var dt = Int(body[off + 14])
    if (dt != DT_F32 and dt != DT_I32) or n <= 0 or off + 16 + 4 * n > len(body):
        raise bad("record dtype " + String(dt) + " or size " + String(n) + " does not fit the body")
    var out = List[Float32](capacity=n)
    var p = off + 16
    for i in range(n):
        var u = UInt32(body[p + 4 * i]) | UInt32(body[p + 4 * i + 1]) << 8 | UInt32(body[p + 4 * i + 2]) << 16 | UInt32(body[p + 4 * i + 3]) << 24
        out.append(Float32(Int(Int32(bitcast[DType.int32](u)))) if dt == DT_I32 else bitcast[DType.float32](u))
    off += 16 + 4 * n
    return out^
