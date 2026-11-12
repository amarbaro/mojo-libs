"""Matrix test server: one TCP port, TLS 1.3 and 1.2 chosen per connection from the ClientHello (the net layer's TlsServer
is TLS 1.2 only). One forked child per connection, so a browser's idle preconnects never block a handshake.
  msrv --mode 12|13|both --port N --alpn h2,http/1.1 --cert CRT --key KEY [--cert CRT --key KEY --name NAME]...
The first --cert is the default; a cert followed by --name NAME answers a client that sent that server_name.
Prints "LISTENING <port>". Every request gets 200 with a tiny HTML page whose second line is "mojo-tls-ok ver=<12|13> sni=<..> alpn=<..>"."""
from std.sys import argv
from std.ffi import external_call
from std.memory import ArcPointer
import aio
from tls.asym import random_bytes
from tls.net.config import TlsConfig, CertEntry
from tls.tls12.realcrypto import RealCrypto
from tls.tls12.server import Server12
from tls.tls12.msg import parse_client_hello
from tls.tls12.wire import bytes_of, str_of
from tls.tls13.server import Server13, ServerConfig
from tls.tls13.conn import EV_CLOSE
from mcommon import *


def reply_body(ver: Int, sni: String, alpn: String) -> List[UInt8]:
    var body = String("mojo-tls-ok ver=" + String(ver) + " sni=" + sni + " alpn=" + alpn + "\n")
    body = "<!doctype html><meta charset=utf-8><body style=\"font:40px monospace\">\n" + body  # the marker stays on its own line; big type for the OCR of a screenshot
    return bytes_of("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: " + String(body.byte_length()) + "\r\n\r\n" + body)


def serve12(fd: Int, cfg: ArcPointer[TlsConfig], first: List[UInt8]) raises:
    var srv = Server12[RealCrypto](cfg)
    var buf = List[UInt8](length=32768, fill=0)
    var req = List[UInt8]()
    var n = len(first)
    var data = first.copy()
    while True:
        try:
            srv.feed(Span(data))
        except e:
            _ = fd_write(fd, srv.cn.take_output())  # the fatal alert
            raise e^
        _ = fd_write(fd, srv.cn.take_output())
        req.extend(srv.cn.take_app())
        if has_end(req):
            srv.cn.write_app(reply_body(12, srv.sni, srv.alpn))
            srv.cn.close()
            _ = fd_write(fd, srv.cn.take_output())
            return
        if srv.cn.peer_closed:
            return
        n = fd_read(fd, buf)
        if n <= 0:
            return
        data = List[UInt8](Span(buf)[0:n])


def serve13(fd: Int, cfg: ArcPointer[TlsConfig], sni: String, first: List[UInt8]) raises:
    var pick = cfg[].order(sni)[0]
    ref e = cfg[].certs[pick]
    var sc = ServerConfig(random_bytes(32), random_bytes(32), random_bytes(32))
    sc.alpn = cfg[].alpn.copy()
    var srv = Server13[Sign13](sc^, Sign13(e.kind, e.key, e.chain.copy()))
    var buf = List[UInt8](length=32768, fill=0)
    var req = List[UInt8]()
    var data = first.copy()
    while True:
        var o = srv.feed(Span(data))
        _ = fd_write(fd, o.send)
        req.extend(Span(o.data))
        if has_end(req):
            _ = fd_write(fd, srv.write(reply_body(13, srv.sni, srv.alpn)))
            _ = fd_write(fd, srv.close())
            return
        if o.error.byte_length() > 0:
            raise Error(o.error)
        if o.has(EV_CLOSE):
            return
        var n = fd_read(fd, buf)
        if n <= 0:
            return
        data = List[UInt8](Span(buf)[0:n])


def handle(fd: Int, cfg: ArcPointer[TlsConfig], mode: Int) raises:
    """Read the whole first record (the ClientHello), pick the engine, replay the bytes into it."""
    var buf = List[UInt8](length=32768, fill=0)
    var first = List[UInt8]()
    while len(first) < 5 or len(first) < 5 + (Int(first[3]) << 8 | Int(first[4])):
        var n = fd_read(fd, buf)
        if n <= 0:
            return
        first.extend(Span(buf)[0:n])
    var sni = String()
    var tls13 = mode != 12  # a hello the 1.2 parser cannot read goes to the TLS 1.3 engine (or Server12 in mode 12): its own alert answers
    try:
        var ch = parse_client_hello(List[UInt8](Span(first)[9 : max(9, 5 + (Int(first[3]) << 8 | Int(first[4])))]))
        sni = ch.sni.copy()
        tls13 = mode == 13 or (mode != 12 and ch.offers13())
    except:
        pass
    if tls13:
        serve13(fd, cfg, sni, first)
    else:
        serve12(fd, cfg, first)


def linger_close(fd: Int32):
    """Half-close, then drain what the peer still sends (1 s idle limit): a close() with unread input resets the connection and the
    client can lose the alert we just queued."""
    _ = external_call["shutdown", Int32](fd, Int32(1))
    var tv = SIMD[DType.int64, 2](1, 0)
    _ = external_call["setsockopt", Int32](fd, Int32(1), Int32(20), Pointer(to=tv), Int32(16))  # SO_RCVTIMEO
    var buf = List[UInt8](length=65536, fill=0)
    for _ in range(4096):
        if aio.read(fd, buf) <= 0:
            break
    aio.close(fd)


def main() raises:
    var a = argv()
    var cfg = TlsConfig()
    var mode = 0
    var port = 0
    var cert = String()
    var key = String()
    var i = 1
    while i + 1 < len(a):
        var k = String(a[i])
        var v = String(a[i + 1])
        if k == "--mode":
            mode = 12 if v == "12" else (13 if v == "13" else 0)
        elif k == "--port":
            port = Int(v)
        elif k == "--alpn":
            for p in v.split(","):
                cfg.alpn.append(String(p))
        elif k == "--cert":
            cert = v
        elif k == "--key":
            key = v
            var chain = List[List[UInt8]]()
            chain.append(pem_der(cert))
            var kd = pem_der(key)
            var names = List[String]()
            names.append(String("localhost"))
            cfg.certs.append(CertEntry(names^, chain^, kd.copy(), key_kind(kd)))
        elif k == "--name":
            cfg.certs[len(cfg.certs) - 1].names = [v]
        i += 2
    cfg.tls13 = mode != 12  # the sentinel only where a TLS 1.3 engine really sits behind
    var lfd = aio.tcp_listen(port, "127.0.0.1", 128)
    print("LISTENING", aio.local_port(lfd), flush=True)
    _ = external_call["signal", Int](Int32(17), Int(1))  # SIGCHLD ignored: children are reaped
    var shared = ArcPointer(cfg^)
    while True:
        var c = aio.accept(lfd)
        if c < 0:
            _ = external_call["usleep", Int32](UInt32(2000))
            continue
        var pid = external_call["fork", Int32]()
        if pid == 0:
            aio.close(lfd)
            _ = external_call["alarm", UInt32](UInt32(20))
            _ = external_call["fcntl", Int32](c, Int32(4), Int32(0))  # blocking
            try:
                handle(Int(c), shared, mode)
            except e:
                print("msrv: " + String(e), flush=True)
            linger_close(c)
            external_call["_exit", NoneType](Int32(0))
        aio.close(c)
