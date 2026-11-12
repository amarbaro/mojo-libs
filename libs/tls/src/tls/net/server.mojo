"""TlsServer: a nonblocking TLS 1.2 server on mojo-aio (one epoll Loop, one thread; run one per core with
SO_REUSEPORT-style separate ports or a front balancer). Per connection: a Server12 engine, an output queue with
partial-write handling (EPOLLOUT armed only while bytes are queued), read pause when the peer does not drain
(cfg.max_out), a handshake deadline and an idle deadline from one timer chain. Plaintext goes to a TlsHandler."""
import aio
from std.memory import ArcPointer
from std.time import perf_counter_ns
from tls.tls12.crypto import Crypto12
from tls.tls12.server import Server12
from .config import TlsConfig

comptime _RD = aio.IN | aio.RDHUP


trait TlsHandler(Movable, Deinitable):
    def handle(mut self, fd: Int, data: List[UInt8], mut reply: List[UInt8]) raises -> Bool:
        """Decrypted bytes arrived on connection fd. Append the answer to reply; return True to close after it is sent."""
        ...


struct Peer[C: Crypto12](Movable):
    var eng: Server12[Self.C]
    var live: Bool
    var gen: Int
    var out: List[UInt8]
    var outp: Int
    var born: Int  # ns
    var last: Int  # ns, last traffic
    var closing: Bool  # close once the queue is drained
    var armed: Bool  # EPOLLOUT is set
    var paused: Bool  # reading stopped: the peer is not draining our output

    def __init__(out self, cfg: ArcPointer[TlsConfig]):
        self.eng = Server12[Self.C](cfg)
        self.live = False
        self.gen = 0
        self.out = List[UInt8]()
        self.outp = 0
        self.born = 0
        self.last = 0
        self.closing = False
        self.armed = False
        self.paused = False


struct TlsServer[C: Crypto12](Movable):
    var cfg: ArcPointer[TlsConfig]
    var loop: aio.Loop
    var lfd: Int32
    var tab: List[Peer[Self.C]]  # indexed by fd
    var rbuf: List[UInt8]
    var gen: Int
    var live: Int
    var handshakes: Int  # completed
    var failed: Int  # closed by an error or alert before the handshake ended
    var timeouts: Int
    var closed: Int  # connections finished, for any reason
    var stopped: Bool

    def __init__(out self, var cfg: TlsConfig, port: Int = 0, host: String = "127.0.0.1") raises:
        self.cfg = ArcPointer(cfg^)
        self.loop = aio.Loop(1024)
        self.lfd = aio.tcp_listen(port, host)
        self.tab = List[Peer[Self.C]]()
        self.rbuf = List[UInt8](length=32768, fill=0)
        self.gen = 0
        self.live = 0
        self.handshakes = 0
        self.failed = 0
        self.timeouts = 0
        self.closed = 0
        self.stopped = False
        self.loop.add(self.lfd, aio.IN, UInt64(self.lfd))

    def port(self) raises -> Int:
        return aio.local_port(self.lfd)

    def _ms_left(self, p: Peer[Self.C], now: Int) -> Int:
        var limit = (self.cfg[].idle_ms if p.eng.cn.established else self.cfg[].handshake_ms) * 1_000_000
        return ((p.born if not p.eng.cn.established else p.last) + limit - now + 999_999) // 1_000_000

    def _drop(mut self, fd: Int):
        ref p = self.tab[fd]
        if not p.live:
            return
        if not p.eng.cn.established:
            self.failed += 1
        p.eng.cn.alert = -1  # no alert, just wipe the secrets
        p.eng.cn.die()
        try:
            self.loop.remove(Int32(fd))
        except:
            pass
        aio.close(Int32(fd))
        p.live = False
        p.out = List[UInt8]()
        p.outp = 0
        self.live -= 1
        self.closed += 1

    def _flush(mut self, fd: Int) raises:
        ref p = self.tab[fd]
        var o = p.eng.cn.take_output()
        if len(o) > 0:
            p.out.extend(o^)
        while p.outp < len(p.out):
            var n = aio.write(Int32(fd), Span(p.out)[p.outp :])
            if n == -2:
                self._drop(fd)
                return
            if n == -1:
                break
            p.outp += n
        var queued = len(p.out) - p.outp
        if queued == 0:
            p.out.clear()
            p.outp = 0
            if p.closing:
                self._drop(fd)
                return
        var want_out = queued > 0
        var pause = queued > self.cfg[].max_out
        if want_out != p.armed or pause != p.paused:
            p.armed = want_out
            p.paused = pause
            var ev = (aio.OUT if want_out else UInt32(0)) | (0 if pause else _RD)
            self.loop.modify(Int32(fd), ev, UInt64(fd) | (UInt64(p.gen) << 32))

    def _read[H: TlsHandler](mut self, fd: Int, mut h: H) raises:
        for _ in range(8):
            ref p = self.tab[fd]
            var n = aio.read(Int32(fd), self.rbuf)
            if n == -1:
                return
            if n <= 0:
                self._drop(fd)  # EOF or error
                return
            p.last = Int(perf_counter_ns())
            var was = p.eng.cn.established
            try:
                p.eng.feed(Span(self.rbuf)[0:n])
            except:
                p.closing = True  # the engine queued the alert
                self._flush(fd)
                return
            if p.eng.cn.established and not was:
                self.handshakes += 1
            var data = p.eng.cn.take_app()
            if len(data) > 0:
                var reply = List[UInt8]()
                var stop = h.handle(fd, data, reply)
                if len(reply) > 0:
                    p.eng.cn.write_app(reply)
                if stop:
                    p.eng.cn.close()
                    p.closing = True
            if p.eng.cn.peer_closed:
                p.closing = True
            self._flush(fd)
            if not self.tab[fd].live or self.tab[fd].paused:
                return

    def step[H: TlsHandler](mut self, mut h: H, timeout_ms: Int = 1000) raises:
        """One pass of the event loop: accept, read, write, expire."""
        var evs = List[aio.Event]()
        _ = self.loop.wait(evs, timeout_ms)
        for ev in evs:
            var fd = Int(ev.token & 0xFFFFFFFF)
            if ev.events & aio.TIMER != 0:
                if fd < len(self.tab) and self.tab[fd].live and self.tab[fd].gen == Int(ev.token >> 32):
                    var left = self._ms_left(self.tab[fd], Int(perf_counter_ns()))
                    if left <= 0:
                        self.timeouts += 1
                        self._drop(fd)
                    else:
                        self.loop.after(left, ev.token)
            elif Int32(fd) == self.lfd:
                self._accept()
            elif fd < len(self.tab) and self.tab[fd].live and self.tab[fd].gen == Int(ev.token >> 32):
                if ev.events & aio.OUT != 0:
                    self._flush(fd)
                if self.tab[fd].live and ev.events & (_RD | aio.ERR | aio.HUP) != 0 and not self.tab[fd].paused:
                    self._read(fd, h)

    def _accept(mut self) raises:
        while True:
            var c = aio.accept(self.lfd)
            if c < 0:
                return
            if self.live >= self.cfg[].max_conns:
                aio.close(c)
                continue
            while len(self.tab) <= Int(c):
                self.tab.append(Peer[Self.C](self.cfg))
            self.gen += 1
            ref p = self.tab[Int(c)]
            p.eng = Server12[Self.C](self.cfg)
            p.live = True
            p.gen = self.gen
            p.out = List[UInt8]()
            p.outp = 0
            p.closing = False
            p.armed = False
            p.paused = False
            p.born = Int(perf_counter_ns())
            p.last = p.born
            self.live += 1
            var tok = UInt64(c) | (UInt64(self.gen) << 32)
            self.loop.add(c, _RD, tok)
            self.loop.after(self.cfg[].handshake_ms, tok)

    def run[H: TlsHandler](mut self, mut h: H) raises:
        while not self.stopped:
            self.step(h)

    def close(mut self):
        for fd in range(len(self.tab)):
            if self.tab[fd].live:
                self._drop(fd)
        aio.close(self.lfd)
