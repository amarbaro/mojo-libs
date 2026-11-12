# X.509 v3 certificate parser (RFC 5280), strict DER, fail closed. Parsing never verifies anything:
# `verify_chain` in chain.mojo decides trust. Fields hold offsets into `raw` or small copies.
from tls.x509.der import Der, Bytes, view, copy_of, same, hex_is

comptime KEY_OTHER = 0
comptime KEY_RSA = 1
comptime KEY_P256 = 2
comptime KEY_P384 = 3

comptime SIG_OTHER = 0
comptime SIG_RSA_SHA1 = 1
comptime SIG_RSA_SHA256 = 2
comptime SIG_RSA_SHA384 = 3
comptime SIG_RSA_SHA512 = 4
comptime SIG_ECDSA_SHA1 = 5
comptime SIG_ECDSA_SHA256 = 6
comptime SIG_ECDSA_SHA384 = 7
comptime SIG_ECDSA_SHA512 = 8
comptime SIG_PSS_SHA256 = 9
comptime SIG_PSS_SHA384 = 10
comptime SIG_PSS_SHA512 = 11

comptime KU_DIGITAL_SIGNATURE = 1
comptime KU_KEY_CERT_SIGN = 32


def _off(base: Bytes, sub: Bytes) -> Int:
    return Int(sub.unsafe_ptr()) - Int(base.unsafe_ptr())


def _hash_id(oid: Bytes) -> Int:
    """0 sha256, 1 sha384, 2 sha512, -1 other (sha1 included: it is never accepted)."""
    if hex_is(oid, "608648016503040201"):
        return 0
    if hex_is(oid, "608648016503040202"):
        return 1
    if hex_is(oid, "608648016503040203"):
        return 2
    return -1


struct Certificate(Copyable, Movable):
    var raw: List[UInt8]
    var tbs_off: Int
    var tbs_len: Int
    var subj_off: Int
    var subj_len: Int
    var iss_off: Int
    var iss_len: Int
    var serial_off: Int
    var serial_len: Int
    var sig_off: Int
    var sig_len: Int
    var version: Int
    var not_before: Int
    var not_after: Int
    var key_kind: Int
    var key_a: List[UInt8]  # RSA modulus, or EC uncompressed point
    var key_b: List[UInt8]  # RSA public exponent
    var sig_alg: Int
    var pss_salt: Int
    var has_bc: Bool
    var is_ca: Bool
    var path_len: Int  # -1: absent
    var has_ku: Bool
    var ku: Int  # bit i of the RFC 5280 KeyUsage BIT STRING is bit i here
    var has_eku: Bool
    var eku_server: Bool  # serverAuth or anyExtendedKeyUsage
    var dns: List[List[UInt8]]
    var ips: List[List[UInt8]]
    var san_types: Int  # bit t set when a GeneralName of type t is present
    var perm_dns: List[List[UInt8]]
    var excl_dns: List[List[UInt8]]
    var perm_ip: List[List[UInt8]]  # address || mask
    var excl_ip: List[List[UInt8]]
    var has_perm_dns: Bool
    var has_perm_ip: Bool
    var nc_unsup: Int  # bit t set when a name constraint of unsupported type t is present
    var unknown_critical: Bool

    def __init__(out self, var raw: List[UInt8]):
        self.raw = raw^
        self.tbs_off = 0
        self.tbs_len = 0
        self.subj_off = 0
        self.subj_len = 0
        self.iss_off = 0
        self.iss_len = 0
        self.serial_off = 0
        self.serial_len = 0
        self.sig_off = 0
        self.sig_len = 0
        self.version = 0
        self.not_before = 0
        self.not_after = 0
        self.key_kind = KEY_OTHER
        self.key_a = List[UInt8]()
        self.key_b = List[UInt8]()
        self.sig_alg = SIG_OTHER
        self.pss_salt = 0
        self.has_bc = False
        self.is_ca = False
        self.path_len = -1
        self.has_ku = False
        self.ku = 0
        self.has_eku = False
        self.eku_server = False
        self.dns = List[List[UInt8]]()
        self.ips = List[List[UInt8]]()
        self.san_types = 0
        self.perm_dns = List[List[UInt8]]()
        self.excl_dns = List[List[UInt8]]()
        self.perm_ip = List[List[UInt8]]()
        self.excl_ip = List[List[UInt8]]()
        self.has_perm_dns = False
        self.has_perm_ip = False
        self.nc_unsup = 0
        self.unknown_critical = False

    @staticmethod
    def parse(var der: List[UInt8]) raises -> Certificate:
        var c = Certificate(der^)
        c._parse()
        return c^

    def _at(self, off: Int, n: Int) -> Bytes:
        return view(self.raw)[off : off + n]

    def tbs(self) -> Bytes:
        return self._at(self.tbs_off, self.tbs_len)

    def subject(self) -> Bytes:
        return self._at(self.subj_off, self.subj_len)

    def issuer(self) -> Bytes:
        return self._at(self.iss_off, self.iss_len)

    def serial(self) -> Bytes:
        return self._at(self.serial_off, self.serial_len)

    def signature(self) -> Bytes:
        return self._at(self.sig_off, self.sig_len)

    def self_issued(self) -> Bool:
        return same(self.subject(), self.issuer())

    def _alg(mut self, mut a: Der) raises -> Bytes:
        """AlgorithmIdentifier for a signature: sets sig_alg / pss_salt, returns the OID."""
        var o = a.oid()
        if hex_is(o, "2a864886f70d010105"):
            self.sig_alg = SIG_RSA_SHA1
        elif hex_is(o, "2a864886f70d01010b"):
            self.sig_alg = SIG_RSA_SHA256
        elif hex_is(o, "2a864886f70d01010c"):
            self.sig_alg = SIG_RSA_SHA384
        elif hex_is(o, "2a864886f70d01010d"):
            self.sig_alg = SIG_RSA_SHA512
        elif hex_is(o, "2a8648ce3d0401"):
            self.sig_alg = SIG_ECDSA_SHA1
        elif hex_is(o, "2a8648ce3d040302"):
            self.sig_alg = SIG_ECDSA_SHA256
        elif hex_is(o, "2a8648ce3d040303"):
            self.sig_alg = SIG_ECDSA_SHA384
        elif hex_is(o, "2a8648ce3d040304"):
            self.sig_alg = SIG_ECDSA_SHA512
        elif hex_is(o, "2a864886f70d01010a"):
            # RSASSA-PSS-params (RFC 4055 3.1): hash, MGF1 with the same hash, salt length (default 20)
            var h = -1
            var mh = -2
            var salt = 20
            if a.peek() == 0x30:
                var ps = a.seq()
                if ps.peek() == 0xA0:
                    var x = ps.wrap(0xA0)
                    h = _hash_id(x.oid())
                if ps.peek() == 0xA1:
                    var x = ps.wrap(0xA1)
                    if hex_is(x.oid(), "2a864886f70d010108"):
                        var y = x.seq()
                        mh = _hash_id(y.oid())
                if ps.peek() == 0xA2:
                    salt = ps.wint(0xA2)
                if ps.peek() == 0xA3:
                    if ps.wint(0xA3) != 1:
                        raise Error("tls: x509: bad pss trailer")
                ps.end()
            if h >= 0 and mh == h:
                self.sig_alg = SIG_PSS_SHA256 + h
                self.pss_salt = salt
        return o

    def _parse(mut self) raises:
        var b = view(self.raw)
        var top = Der(b)
        var cert = top.seq()
        top.end()
        var tbs = cert.seq()
        self.tbs_off = _off(b, cert.full)
        self.tbs_len = len(cert.full)
        var outer = cert.seq()
        var outer_alg = outer.b
        var sig = cert.bits()
        if cert.unused != 0:
            raise Error("tls: x509: bad signature bits")
        self.sig_off = _off(b, sig)
        self.sig_len = len(sig)
        cert.end()

        if tbs.peek() == 0xA0:
            self.version = tbs.wint(0xA0)
            if self.version > 2:
                raise Error("tls: x509: unsupported version")
        var s = tbs.int_raw()
        self.serial_off = _off(b, s)
        self.serial_len = len(s)
        var ia = tbs.seq()
        _ = self._alg(ia)
        if not same(ia.b, outer_alg):
            raise Error("tls: x509: signature algorithm mismatch")
        _ = tbs.next(0x30)
        self.iss_off = _off(b, tbs.full)
        self.iss_len = len(tbs.full)
        var val = tbs.seq()
        self.not_before = val.time()
        self.not_after = val.time()
        val.end()
        _ = tbs.next(0x30)
        self.subj_off = _off(b, tbs.full)
        self.subj_len = len(tbs.full)
        self._spki(tbs.seq())
        if tbs.peek() == 0xA1 or tbs.peek() == 0xA2:
            if self.version == 0:
                raise Error("tls: x509: unique id in v1")
            while tbs.peek() == 0xA1 or tbs.peek() == 0xA2:
                _ = tbs.next()
        if tbs.peek() == 0xA3:
            if self.version != 2:
                raise Error("tls: x509: extensions need v3")
            var xs = tbs.wrap(0xA3)
            self._exts(xs)
        tbs.end()

    def _spki(mut self, var sp: Der) raises:
        var al = sp.seq()
        var o = al.oid()
        var kb = sp.bits()
        if sp.unused != 0:
            raise Error("tls: x509: bad key bits")
        sp.end()
        if hex_is(o, "2a864886f70d010101"):
            var kd = Der(kb)
            var k = kd.seq()
            self.key_a = copy_of(k.int_bytes())
            self.key_b = copy_of(k.int_bytes())
            k.end()
            self.key_kind = KEY_RSA
        elif hex_is(o, "2a8648ce3d0201"):
            var cv = al.oid()
            var want = 0
            if hex_is(cv, "2a8648ce3d030107"):
                self.key_kind = KEY_P256
                want = 65
            elif hex_is(cv, "2b81040022"):
                self.key_kind = KEY_P384
                want = 97
            if want > 0:
                if len(kb) != want or kb[0] != 4:
                    raise Error("tls: x509: bad ec point")
                self.key_a = copy_of(kb)

    def _exts(mut self, mut xs: Der) raises:
        var seen = List[List[UInt8]]()
        while not xs.done():
            var e = xs.seq()
            var o = e.oid()
            for ref p in seen:
                if same(view(p), o):
                    raise Error("tls: x509: duplicate extension")
            seen.append(copy_of(o))
            var crit = False
            if e.peek() == 0x01:
                crit = e.boolean()
            var v = e.octets()
            e.end()
            if hex_is(o, "551d13"):
                self._bc(v)
            elif hex_is(o, "551d0f"):
                var d = Der(v)
                var kb = d.bits()
                d.end()
                self.has_ku = True
                for i in range(min(9, len(kb) * 8)):
                    if (Int(kb[i // 8]) >> (7 - i % 8)) & 1 == 1:
                        self.ku |= 1 << i
            elif hex_is(o, "551d25"):
                var d = Der(v)
                var l = d.seq()
                d.end()
                if l.done():
                    raise Error("tls: x509: empty eku")
                self.has_eku = True
                while not l.done():
                    var k = l.oid()
                    if hex_is(k, "2b06010505070301") or hex_is(k, "551d2500"):
                        self.eku_server = True
            elif hex_is(o, "551d11"):
                self._san(v)
            elif hex_is(o, "551d1e"):
                self._nc(v)
            elif crit and not (
                hex_is(o, "551d0e")
                or hex_is(o, "551d23")
                or hex_is(o, "551d20")
                or hex_is(o, "551d1f")
                or hex_is(o, "2b06010505070101")
                or hex_is(o, "551d12")
                or hex_is(o, "551d09")
                or hex_is(o, "551d2e")
                or hex_is(o, "2b06010401d679020402")
            ):
                self.unknown_critical = True

    def _bc(mut self, v: Bytes) raises:
        var d = Der(v)
        var s = d.seq()
        d.end()
        self.has_bc = True
        if s.peek() == 0x01:
            self.is_ca = s.boolean()
        if s.peek() == 0x02:
            self.path_len = s.small_int()
        s.end()

    def _san(mut self, v: Bytes) raises:
        var d = Der(v)
        var s = d.seq()
        d.end()
        if s.done():
            raise Error("tls: x509: empty san")
        while not s.done():
            var n = s.next()
            var t = s.tag & 0x1F
            self.san_types |= 1 << t
            if s.tag == 0x82:
                self.dns.append(copy_of(n))
            elif s.tag == 0x87:
                if len(n) != 4 and len(n) != 16:
                    raise Error("tls: x509: bad san ip")
                self.ips.append(copy_of(n))

    def _nc(mut self, v: Bytes) raises:
        var d = Der(v)
        var s = d.seq()
        d.end()
        while not s.done():
            var excl = s.peek() == 0xA1
            if not excl and s.peek() != 0xA0:
                raise Error("tls: x509: bad name constraints")
            var l = s.sub(s.peek())
            while not l.done():
                var g = l.seq()
                var base = g.next()
                var t = g.tag
                if not g.done():
                    raise Error("tls: x509: name constraint min/max")
                if t == 0x82:
                    if excl:
                        self.excl_dns.append(copy_of(base))
                    else:
                        self.perm_dns.append(copy_of(base))
                        self.has_perm_dns = True
                elif t == 0x87:
                    if len(base) != 8 and len(base) != 32:
                        raise Error("tls: x509: bad ip constraint")
                    if excl:
                        self.excl_ip.append(copy_of(base))
                    else:
                        self.perm_ip.append(copy_of(base))
                        self.has_perm_ip = True
                else:
                    self.nc_unsup |= 1 << (t & 0x1F)
