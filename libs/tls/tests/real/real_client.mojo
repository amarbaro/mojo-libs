"""TLS_CLIENT_BIN for tests/interop/run.sh TlsStream over RealCrypto.
real_client HOST PORT CAFILE: GET /marker.txt, prints the response. The chain is NOT validated (CAFILE is ignored,
lane 3 does that), only the ServerKeyExchange signature with the leaf key."""
from std.sys import argv
from tls.tls12.realcrypto import RealCrypto
from tls.net.stream import tls_connect
from tls.tls12.wire import bytes_of, str_of


def main() raises:
    var a = argv()
    var s = tls_connect[RealCrypto]("localhost", Int(a[2]), ["http/1.1"], String(a[1]))
    s.write(bytes_of("GET /marker.txt HTTP/1.0\r\nHost: localhost\r\n\r\n"))
    var got = List[UInt8]()
    while s.read(got) > 0:
        pass
    s.close()
    print(str_of(got))
