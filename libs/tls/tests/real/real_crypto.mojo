"""TEMPORARY real Crypto12 for wave-1 interop: lane 4's `_tmp_crypto` (a port of Mosaad-M-tls, MIT) behind the
trait, so Server12/Client12 can meet openssl, curl, python and Chromium before lanes 1-3 land. Wave 2 replaces it
with RealCrypto over lanes 1-3. Scope: ECDSA P-256 certificates (scheme 0x0403), x25519 and P-256 ECDH, SHA-256/384,
AES-GCM, ChaCha20-Poly1305. Anything else raises. The client side checks the ServerKeyExchange signature with the
leaf key but does NOT validate the chain (lane 3): never use it outside tests. Build with tests/real/build.sh."""
from tls.tls12.crypto import Crypto12, K_P256
from tls.tls13._tmp_crypto.hash import sha256, sha384
from tls.tls13._tmp_crypto.hmac import hmac_sha256, hmac_sha384
from tls.tls13._tmp_crypto.gcm import gcm_encrypt, gcm_decrypt
from tls.tls13._tmp_crypto.poly1305 import chacha20_poly1305_encrypt, chacha20_poly1305_decrypt
from tls.tls13._tmp_crypto.curve25519 import x25519_public_key, x25519_shared
from tls.tls13._tmp_crypto.p256 import p256_public_key, p256_ecdh, p256_ecdsa_sign, p256_ecdsa_verify
from tls.tls13._tmp_crypto.random import csprng_bytes
from tls.tls12.wire import cat, bytes_of


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


def int32(sig: List[UInt8], at: Int, n: Int) raises -> List[UInt8]:
    var i = at
    while i < at + n and sig[i] == 0:
        i += 1
    if at + n - i > 32:
        raise Error("ecdsa integer too long")
    var o = List[UInt8](length=32 - (at + n - i), fill=0)
    for k in range(i, at + n):
        o.append(sig[k])
    return o^


def find(hay: List[UInt8], pat: List[UInt8]) -> Int:
    for i in range(len(hay) - len(pat) + 1):
        var hit = True
        for j in range(len(pat)):
            if hay[i + j] != pat[j]:
                hit = False
                break
        if hit:
            return i
    return -1


struct RealCrypto(Crypto12):
    def __init__(out self):
        pass

    def random(self, n: Int) raises -> List[UInt8]:
        return csprng_bytes(n)

    def hash(self, sha384: Bool, data: List[UInt8]) -> List[UInt8]:
        return tls13_sha384(data) if sha384 else sha256(data)

    def prf(self, sha384: Bool, secret: List[UInt8], label: String, seed: List[UInt8], n: Int) -> List[UInt8]:
        var s = cat(bytes_of(label), seed)
        var a = s.copy()
        var out = List[UInt8]()
        while len(out) < n:
            a = hmac_sha384(secret, a) if sha384 else hmac_sha256(secret, a)
            var blk = hmac_sha384(secret, cat(a, s)) if sha384 else hmac_sha256(secret, cat(a, s))
            out.extend(blk^)
        out.resize(n, 0)
        return out^

    def keygen(self, group: Int) raises -> Tuple[List[UInt8], List[UInt8]]:
        var k = csprng_bytes(32)
        if group == 0x001D:
            return (k.copy(), x25519_public_key(k))
        if group == 0x0017:
            return (k.copy(), p256_public_key(k))
        raise Error("RealCrypto: group not supported")

    def ecdh(self, group: Int, secret: List[UInt8], peer: List[UInt8]) raises -> List[UInt8]:
        if group == 0x001D:
            return x25519_shared(secret, peer)
        if group == 0x0017:
            return p256_ecdh(secret, peer)
        raise Error("RealCrypto: group not supported")

    def sign(self, kind: Int, key_der: List[UInt8], scheme: Int, msg: List[UInt8]) raises -> List[UInt8]:
        if kind != K_P256 or scheme != 0x0403:
            raise Error("RealCrypto: only ECDSA P-256 signing")
        var at = find(key_der, [2, 1, 1, 4, 0x20])  # ECPrivateKey: version 1, OCTET STRING of 32 bytes
        if at < 0 or at + 5 + 32 > len(key_der):
            raise Error("RealCrypto: no P-256 scalar in the key")
        var rs = p256_ecdsa_sign(List[UInt8](Span(key_der)[at + 5 : at + 37]), sha256(msg), csprng_bytes(32))
        var body = cat(der_int(rs[0]), der_int(rs[1]))
        return cat([UInt8(0x30), UInt8(len(body))], body)

    def verify(self, chain: List[List[UInt8]], host: String, scheme: Int, msg: List[UInt8], sig: List[UInt8]) raises:
        if scheme != 0x0403:
            raise Error("RealCrypto: only ECDSA P-256 verification")
        var at = find(chain[0], [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04])
        if at < 0 or at + 14 + 64 > len(chain[0]):
            raise Error("RealCrypto: no P-256 key in the certificate")
        var pub = List[UInt8](Span(chain[0])[at + 13 : at + 13 + 65])
        if len(sig) < 8 or sig[0] != 0x30 or Int(sig[1]) != len(sig) - 2 or sig[2] != 2:
            raise Error("RealCrypto: bad ECDSA DER")
        var rl = Int(sig[3])
        if 6 + rl > len(sig) or sig[4 + rl] != 2:
            raise Error("RealCrypto: bad ECDSA DER")
        var sl = Int(sig[5 + rl])
        if 6 + rl + sl != len(sig):
            raise Error("RealCrypto: bad ECDSA DER")
        p256_ecdsa_verify(pub, sha256(msg), int32(sig, 4, rl), int32(sig, 6 + rl, sl))

    def seal(self, aead: Int, key: List[UInt8], nonce: List[UInt8], aad: List[UInt8], mut buf: List[UInt8], start: Int) raises:
        var pt = List[UInt8](Span(buf)[start:])
        var r = gcm_encrypt(key, nonce, pt, aad) if aead < 2 else chacha20_poly1305_encrypt(key, nonce, aad, pt)
        for i in range(len(r[0])):
            buf[start + i] = r[0][i]
        buf.extend(r[1].copy())

    def open(self, aead: Int, key: List[UInt8], nonce: List[UInt8], aad: List[UInt8], mut buf: List[UInt8], start: Int, end: Int) raises:
        var ct = List[UInt8](Span(buf)[start : end - 16])
        var tag = List[UInt8](Span(buf)[end - 16 : end])
        var pt = gcm_decrypt(key, nonce, ct, tag, aad) if aead < 2 else chacha20_poly1305_decrypt(key, nonce, aad, ct, tag)
        for i in range(len(pt)):
            buf[start + i] = pt[i]


def tls13_sha384(data: List[UInt8]) -> List[UInt8]:
    return sha384(data)
