"""Matrix test server: the product TlsServer (src/tls/net, nonblocking, TLS 1.3 and 1.2 chosen per connection from the
ClientHello) over RealCrypto, so every matrix cell exercises the shipped server.
  msrv --mode 12|13|both --port N --alpn h2,http/1.1 --cert CRT --key KEY [--cert CRT --key KEY --name NAME]...
The first --cert is the default; a cert followed by --name NAME answers a client that sent that server_name.
Prints "LISTENING <port>". Every request gets 200 with a tiny HTML page whose second line is "mojo-tls-ok ver=<12|13> sni=<..> alpn=<..>"."""
from std.sys import argv
from std.memory import ArcPointer
from std.collections import Dict
import aio
from tls.net.config import TlsConfig, CertEntry
from tls.net.server import TlsServer, TlsHandler, ConnInfo
from tls.tls12.realcrypto import RealCrypto
from tls.tls12.wire import bytes_of, str_of
from mcommon import *


def reply_body(ver: Int, sni: String, alpn: String) -> List[UInt8]:
    var body = String("mojo-tls-ok ver=" + String(ver) + " sni=" + sni + " alpn=" + alpn + "\n")
    body = "<!doctype html><meta charset=utf-8><body style=\"font:40px monospace\">\n" + body  # the marker stays on its own line; big type for the OCR of a screenshot
    return bytes_of("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: " + String(body.byte_length()) + "\r\n\r\n" + body)


struct Reply(TlsHandler):
    """Collects each request until its blank line, answers the marker page, closes."""

    var req: Dict[Int, List[UInt8]]

    def __init__(out self):
        self.req = Dict[Int, List[UInt8]]()

    def handle(mut self, fd: Int, info: ConnInfo, data: List[UInt8], mut reply: List[UInt8]) raises -> Bool:
        var b = self.req.pop(fd, List[UInt8]())
        b.extend(Span(data))
        if not has_end(b):
            self.req[fd] = b^
            return False
        reply.extend(Span(reply_body(info.ver, info.sni, info.alpn)))
        return True


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
    cfg.tls12 = mode != 13
    cfg.handshake_ms = 330000  # tlsfuzzer test-tls13-finished sends 16 MiB of Finished (about 20 s) and waits up to 300 s for our alert
    cfg.idle_ms = 330000
    var srv = TlsServer[RealCrypto](cfg^, port, "127.0.0.1", mode != 12)
    print("LISTENING", srv.port(), flush=True)
    var h = Reply()
    srv.run(h)
