# Private key loading: PKCS#8, SEC1 and PKCS#1 from PEM. P-256 and RSA (>= 2048 bits, two primes) only.
# Secret handling: base64 is branchless, every buffer holding key bytes is zeroed on success and failure
# (explicit_bzero, which the compiler may not drop), the EC scalar is range-checked and multiplied in constant time,
# errors never carry key bytes. The RSA consistency check uses variable-time bigint code: it runs once at load,
# offline, with no peer in the loop.
from std.ffi import external_call
from tls.x509.cert import Certificate, KEY_RSA, KEY_P256
from tls.x509.der import Der, Bytes, view, copy_of, same, hex_is
from tls.x509.pem import pem_spans, b64_decode
from tls.x509.sigs import rsa_bits, MIN_RSA_BITS
from tls.x509.shim.bigint import BigInt, bigint_from_bytes, bigint_mul, bigint_mod, bigint_sub, bigint_cmp, bigint_one
from tls.x509.shim.rsa import _rsa_raw
import tls.x509.shim.ec_ct as ct


def wipe(mut l: List[UInt8]):
    if len(l) > 0:
        _ = external_call["explicit_bzero", Int](l.unsafe_ptr(), len(l))


def _wipe_big(mut b: BigInt):
    _ = external_call["explicit_bzero", Int](b.limbs.unsafe_ptr(), len(b.limbs) * 4)


struct PrivateKey(Movable):
    var kind: Int  # KEY_P256 or KEY_RSA
    var d: List[UInt8]  # EC scalar (32 bytes) or RSA private exponent
    var pub: List[UInt8]  # EC: 65-byte point; RSA: modulus
    var e: List[UInt8]
    var p: List[UInt8]
    var q: List[UInt8]
    var dp: List[UInt8]
    var dq: List[UInt8]
    var qinv: List[UInt8]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.d = List[UInt8]()
        self.pub = List[UInt8]()
        self.e = List[UInt8]()
        self.p = List[UInt8]()
        self.q = List[UInt8]()
        self.dp = List[UInt8]()
        self.dq = List[UInt8]()
        self.qinv = List[UInt8]()

    def __deinit__(deinit self):
        wipe(self.d)
        wipe(self.p)
        wipe(self.q)
        wipe(self.dp)
        wipe(self.dq)
        wipe(self.qinv)

    def matches(self, c: Certificate) -> Bool:
        """True when `c` certifies this key's public half."""
        return c.key_kind == self.kind and same(c.key_a, self.pub)


def _rsa_ok(k: PrivateKey) -> Bool:
    var n = bigint_from_bytes(k.pub)
    var e = bigint_from_bytes(k.e)
    var p = bigint_from_bytes(k.p)
    var q = bigint_from_bytes(k.q)
    var d = bigint_from_bytes(k.d)
    var dp = bigint_from_bytes(k.dp)
    var dq = bigint_from_bytes(k.dq)
    var qi = bigint_from_bytes(k.qinv)
    var one = bigint_one()
    var pq = BigInt()
    var r1 = BigInt()
    var r2 = BigInt()
    var r3 = BigInt()
    var ok = bigint_cmp(p, one) > 0 and bigint_cmp(q, one) > 0 and bigint_cmp(d, n) < 0 and (k.e[len(k.e) - 1] & 1) == 1
    if ok:
        pq = bigint_mul(p, q)
        r1 = bigint_mod(d, bigint_sub(p, one))
        r2 = bigint_mod(d, bigint_sub(q, one))
        r3 = bigint_mod(bigint_mul(qi, q), p)
        ok = bigint_cmp(pq, n) == 0 and bigint_cmp(r1, dp) == 0 and bigint_cmp(r2, dq) == 0 and bigint_cmp(r3, one) == 0
    if ok:
        # sign then verify: m^d^e == m ties d, e and n together
        try:
            var m = List[UInt8](length=len(k.pub), fill=0)
            m[len(m) - 3] = 1
            m[len(m) - 1] = 1
            var s = _rsa_raw(m, k.pub, k.d, len(k.pub))
            var back = _rsa_raw(s, k.pub, k.e, len(k.pub))
            ok = same(back, m)
            wipe(s)
        except:
            ok = False
    _wipe_big(d)
    _wipe_big(dp)
    _wipe_big(dq)
    _wipe_big(qi)
    _wipe_big(p)
    _wipe_big(q)
    _wipe_big(pq)
    _wipe_big(r1)
    _wipe_big(r2)
    _wipe_big(r3)
    return ok


def _rsa(mut s: Der) raises -> PrivateKey:
    var ver = s.small_int()
    if ver == 1:
        raise Error("tls: key: unsupported multi-prime RSA key")
    if ver != 0:
        raise Error("tls: key: invalid key")
    var k = PrivateKey(KEY_RSA)
    k.pub = copy_of(s.int_bytes())
    k.e = copy_of(s.int_bytes())
    k.d = copy_of(s.int_bytes())
    k.p = copy_of(s.int_bytes())
    k.q = copy_of(s.int_bytes())
    k.dp = copy_of(s.int_bytes())
    k.dq = copy_of(s.int_bytes())
    k.qinv = copy_of(s.int_bytes())
    s.end()
    if rsa_bits(k.pub) < MIN_RSA_BITS:
        raise Error("tls: key: unsupported RSA key below 2048 bits")
    if not _rsa_ok(k):
        raise Error("tls: key: invalid key")
    return k^


def _ec(mut s: Der, var curve: List[UInt8]) raises -> PrivateKey:
    if s.small_int() != 1:
        raise Error("tls: key: invalid key")
    var raw = copy_of(s.octets())
    var given = List[UInt8]()
    if s.peek() == 0xA0:
        var w = Der(s.next(0xA0))
        curve = copy_of(w.oid())
        w.end()
    if s.peek() == 0xA1:
        var w = Der(s.next(0xA1))
        given = copy_of(w.bits())
        if w.unused != 0:
            raise Error("tls: key: invalid key")
        w.end()
    s.end()
    if (len(curve) > 0 and not hex_is(curve, "2a8648ce3d030107")) or len(raw) > 32:
        wipe(raw)
        raise Error("tls: key: unsupported curve (only P-256)")
    var k = PrivateKey(KEY_P256)
    k.d = List[UInt8](length=32 - len(raw), fill=0)
    k.d.extend(raw.copy())
    wipe(raw)
    var c = ct.p256_curve()
    if len(k.d) != 32:  # the range check is ct.public_key's (constant time)
        raise Error("tls: key: invalid key")
    k.pub = ct.public_key(k.d, c)
    if len(given) > 0 and not same(given, k.pub):
        raise Error("tls: key: invalid key")
    return k^


def _parse(fmt: Int, der: Bytes) raises -> PrivateKey:
    var top = Der(der)
    var s = top.seq()
    top.end()
    if fmt == 2:
        return _rsa(s)
    if fmt == 1:
        return _ec(s, List[UInt8]())
    var ver = s.small_int()
    if ver != 0:
        raise Error("tls: key: unsupported PKCS#8 version")
    var alg = s.seq()
    var oid = alg.oid()
    var is_rsa = hex_is(oid, "2a864886f70d010101")
    if not is_rsa and not hex_is(oid, "2a8648ce3d0201"):
        raise Error("tls: key: unsupported key algorithm")
    var inner = Der(s.octets())
    if s.peek() == 0xA0:
        _ = s.next()
    s.end()
    var body = inner.seq()
    inner.end()
    if is_rsa:
        return _rsa(body)
    return _ec(body, copy_of(alg.oid()))


def load_private_key(pem: Span[UInt8, _]) raises -> PrivateKey:
    """First PRIVATE KEY / EC PRIVATE KEY / RSA PRIVATE KEY block of `pem`. Encrypted keys are refused."""
    var text = view(pem)
    for ref sp in pem_spans(text):
        var fmt = 0
        if same(sp[0], "PRIVATE KEY".as_bytes()):
            fmt = 8
        elif same(sp[0], "EC PRIVATE KEY".as_bytes()):
            fmt = 1
        elif same(sp[0], "RSA PRIVATE KEY".as_bytes()):
            fmt = 2
        elif same(sp[0], "ENCRYPTED PRIVATE KEY".as_bytes()):
            raise Error("tls: key: unsupported encrypted private key")
        else:
            continue
        var body = sp[1]
        var i = 0
        while i < len(body) and (body[i] == 10 or body[i] == 13 or body[i] == 32):
            i += 1
        if len(body) - i > 10 and same(body[i : i + 10], "Proc-Type:".as_bytes()):
            raise Error("tls: key: unsupported encrypted private key")
        var der = b64_decode(body)
        try:
            var k = _parse(fmt, view(der))
            wipe(der)
            return k^
        except e:
            wipe(der)
            if String(e).startswith("tls: key: unsupported"):
                raise e
            raise Error("tls: key: invalid key")
    raise Error("tls: key: no private key block")


def load_private_key_file(path: String) raises -> PrivateKey:
    """Read `path`, load the key, zero the file buffer."""
    var raw: List[UInt8]
    with open(path, "r") as f:
        raw = f.read_bytes()
    try:
        var k = load_private_key(raw)
        wipe(raw)
        return k^
    except e:
        wipe(raw)
        raise e
