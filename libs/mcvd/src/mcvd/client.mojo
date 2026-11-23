"""mcvd client stub: one blocking request over a connected socket. R2b adds reconnect and per-op deadlines."""
from posix import send_all, recv, PollSet, POLLIN
from mcvd.proto import Frame, FrameBuf, KIND_REQ, pack


def call(fd: Int32, id: UInt64, hdr: List[UInt8], body: List[UInt8], timeout_ms: Int = 20000) raises -> Frame:
    """Send request `id` and return the reply frame; raises when the peer closes or stays silent for `timeout_ms`."""
    if not send_all(fd, Span(pack(KIND_REQ, id, hdr, body))):
        raise Error("FAIL client: send failed, the daemon closed the connection")
    return read_reply(fd, timeout_ms)


def read_reply(fd: Int32, timeout_ms: Int) raises -> Frame:
    var fb = FrameBuf()
    var f = Frame()
    var ps = PollSet()
    _ = ps.add(fd, POLLIN)
    while True:
        var s = fb.next(f, 0)
        if s > 0:
            return f^
        if s < 0:
            raise Error("FAIL client: bad reply frame: " + fb.fault)
        if ps.wait(timeout_ms) <= 0:
            raise Error("FAIL client: no reply within " + String(timeout_ms) + " ms")
        if recv(fd, fb.buf) == 0:
            raise Error("closed")
