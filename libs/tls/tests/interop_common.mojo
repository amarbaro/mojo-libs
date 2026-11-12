# Shared by the interop programs: a P-256 Signer and a certificate-pinning Verifier (ECDSA only, test use: lane 3's
# X.509 path validation replaces the pinning in wave 2), DER signature helpers and raw fd I/O for stdio relays.
from std.ffi import external_call
from tls.tls13._tmp_crypto.hash import sha256
from tls.tls13._tmp_crypto.p256 import p256_ecdsa_sign, p256_ecdsa_verify
from tls.tls13._tmp_crypto.random import csprng_bytes
from tls.tls13.verify import Signer, Verifier
from tls.tls13.wire import bad
from chk import hexd


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def read_hex_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return hexd(f.read())


def der_int(x: List[UInt8]) -> List[UInt8]:
    var i = 0
    while i < len(x) - 1 and x[i] == 0:
        i += 1
    var o = List[UInt8]()
    o.append(2)
    var neg = x[i] >= 0x80
    o.append(UInt8(len(x) - i + (1 if neg else 0)))
    if neg:
        o.append(0)
    for k in range(i, len(x)):
        o.append(x[k])
    return o^


def der_sig(r: List[UInt8], s: List[UInt8]) -> List[UInt8]:
    var body = der_int(r)
    body.extend(Span(der_int(s)))
    var o = List[UInt8]()
    o.append(0x30)
    o.append(UInt8(len(body)))
    o.extend(Span(body))
    return o^


def fixed32(x: List[UInt8], a: Int, n: Int) raises -> List[UInt8]:
    """INTEGER content x[a:a+n] as 32 big-endian bytes."""
    var i = a
    var end = a + n
    while i < end and x[i] == 0:
        i += 1
    if end - i > 32:
        raise bad("decode_error", "ECDSA integer longer than 32 bytes")
    var o = List[UInt8](length=32 - (end - i), fill=0)
    for k in range(i, end):
        o.append(x[k])
    return o^


def parse_der_sig(sig: List[UInt8]) raises -> Tuple[List[UInt8], List[UInt8]]:
    if len(sig) < 8 or sig[0] != 0x30 or Int(sig[1]) != len(sig) - 2 or sig[2] != 2:
        raise bad("decode_error", "ECDSA signature DER")
    var rl = Int(sig[3])
    if 4 + rl + 2 > len(sig) or sig[4 + rl] != 2:
        raise bad("decode_error", "ECDSA signature DER")
    var sl = Int(sig[5 + rl])
    if 6 + rl + sl != len(sig):
        raise bad("decode_error", "ECDSA signature DER")
    return (fixed32(sig, 4, rl), fixed32(sig, 6 + rl, sl))


struct P256Signer(Signer):
    var key: List[UInt8]
    var cert: List[UInt8]

    def __init__(out self, key: List[UInt8], cert: List[UInt8]):
        self.key = key.copy()
        self.cert = cert.copy()

    def schemes(self) -> List[Int]:
        return [0x0403]

    def chain(self) -> List[List[UInt8]]:
        var c = List[List[UInt8]]()
        c.append(self.cert.copy())
        return c^

    def sign(self, scheme: Int, content: List[UInt8]) raises -> List[UInt8]:
        var rs = p256_ecdsa_sign(self.key, sha256(content), csprng_bytes(32))
        return der_sig(rs[0], rs[1])


struct P256Pinned(Verifier):
    """Accepts exactly the pinned certificate and checks its ECDSA CertificateVerify signature."""

    var cert: List[UInt8]

    def __init__(out self, cert: List[UInt8]):
        self.cert = cert.copy()

    def verify(
        mut self, chain: List[List[UInt8]], scheme: Int, signed: List[UInt8], sig: List[UInt8], host: String
    ) raises:
        if len(chain) == 0 or chain[0] != self.cert:
            raise bad("bad_certificate", "not the pinned certificate")
        if scheme != 0x0403:
            raise bad("illegal_parameter", "scheme")
        # the SubjectPublicKeyInfo of a P-256 key ends in: OID prime256v1, BIT STRING 03 42 00, 04 || X || Y
        var pat: List[UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04]
        var at = -1
        for i in range(len(self.cert) - len(pat) - 63):
            var hit = True
            for j in range(len(pat)):
                if self.cert[i + j] != pat[j]:
                    hit = False
                    break
            if hit:
                at = i + len(pat) - 1
                break
        if at < 0:
            raise bad("bad_certificate", "no P-256 key in the certificate")
        var pub = List[UInt8](capacity=65)
        for k in range(65):
            pub.append(self.cert[at + k])
        var rs = parse_der_sig(sig)
        try:
            p256_ecdsa_verify(pub, sha256(signed), rs[0], rs[1])
        except e:
            raise bad("decrypt_error", "CertificateVerify signature")


def fd_read(fd: Int, mut buf: List[UInt8]) -> Int:
    return Int(external_call["__read", Int](fd, buf.unsafe_ptr(), len(buf)))


def fd_write(fd: Int, data: List[UInt8]) -> Int:
    var done = 0
    while done < len(data):
        var n = Int(external_call["__write", Int](fd, data.unsafe_ptr() + done, len(data) - done))
        if n <= 0:
            return -1
        done += n
    return done
