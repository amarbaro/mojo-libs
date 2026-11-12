# Chain path validation (RFC 5280 6.1 as a TLS client needs it), hostname matching (RFC 9525: SAN only, no CN),
# and the system root store. Time is a parameter (epoch seconds). Order of work: find a path by names ending in a
# trusted root, run the structural checks, then verify signatures top-down from the root, so a key supplied by
# the peer is used only after the root has vouched for it.
from std.sys import stderr
from tls.x509.cert import *
from tls.x509.der import Bytes, view, same
from tls.x509.pem import pem_spans, b64_decode
from tls.x509.sigs import verify_sig, rsa_bits, MIN_RSA_BITS

comptime MAX_CHAIN = 10
comptime MAX_SIG_ATTEMPTS = 16


# ---------------------------------------------------------------- names
def _lower(b: Bytes) -> List[UInt8]:
    var o = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        o.append(b[i] + 32 if b[i] >= 65 and b[i] <= 90 else b[i])
    return o^


def _ends_with(a: List[UInt8], suffix: List[UInt8]) -> Bool:
    if len(suffix) > len(a):
        return False
    for i in range(len(suffix)):
        if a[len(a) - len(suffix) + i] != suffix[i]:
            return False
    return True


def parse_ip(h: Bytes) -> List[UInt8]:
    """4 or 16 address bytes of a dotted-quad or colon-hex literal; empty when `h` is not an IP literal."""
    var out = List[UInt8]()
    var n = len(h)
    var colon = False
    for i in range(n):
        if h[i] == 58:
            colon = True
    if not colon:
        var v = 0
        var nd = 0
        for i in range(n + 1):
            if i < n and h[i] >= 48 and h[i] <= 57:
                if nd > 0 and v == 0:
                    return List[UInt8]()  # leading zero
                v = v * 10 + Int(h[i]) - 48
                nd += 1
            elif (i == n or h[i] == 46) and nd > 0 and v < 256 and len(out) < 4:
                out.append(UInt8(v))
                v = 0
                nd = 0
            else:
                return List[UInt8]()
        return out^ if len(out) == 4 else List[UInt8]()
    var head = List[Int]()
    var tail = List[Int]()
    var gap = False
    var i = 0
    if n >= 2 and h[0] == 58 and h[1] == 58:
        gap = True
        i = 2
    while i < n:
        var v = 0
        var nd = 0
        while i < n and h[i] != 58:
            var c = Int(h[i])
            var d = c - 48 if c >= 48 and c <= 57 else (c - 87 if c >= 97 and c <= 102 else (c - 55 if c >= 65 and c <= 70 else -1))
            if d < 0:
                return List[UInt8]()
            v = v * 16 + d
            nd += 1
            i += 1
        if nd == 0 or nd > 4:
            return List[UInt8]()
        if gap:
            tail.append(v)
        else:
            head.append(v)
        if i == n:
            break
        i += 1
        if i < n and h[i] == 58:
            if gap:
                return List[UInt8]()
            gap = True
            i += 1
        elif i == n:
            return List[UInt8]()
    var total = len(head) + len(tail)
    if (gap and total > 7) or (not gap and total != 8):
        return List[UInt8]()
    for g in head:
        out.append(UInt8(g >> 8))
        out.append(UInt8(g & 255))
    for _ in range(8 - total):
        out.append(0)
        out.append(0)
    for g in tail:
        out.append(UInt8(g >> 8))
        out.append(UInt8(g & 255))
    return out^


def _wild_match(pat: List[UInt8], host: List[UInt8]) -> Bool:
    """RFC 6125 6.4.3: `*` is the whole left-most label, with at least two labels after it."""
    if len(pat) < 4 or pat[0] != 42 or pat[1] != 46:
        return False
    var rest = List[UInt8]()
    var dots = 0
    for i in range(2, len(pat)):
        if pat[i] == 42:
            return False
        if pat[i] == 46:
            dots += 1
        rest.append(pat[i])
    if dots < 1 or rest[0] == 46 or rest[len(rest) - 1] == 46:
        return False
    var d = 0
    while d < len(host) and host[d] != 46:
        d += 1
    if d == 0 or d >= len(host):
        return False
    if len(host) - d - 1 != len(rest):
        return False
    for i in range(len(rest)):
        if host[d + 1 + i] != rest[i]:
            return False
    return True


def host_matches(c: Certificate, host: Bytes) -> Bool:
    """SAN-only match of a DNS name or IP literal (a single trailing dot on a DNS name is ignored)."""
    var h = host
    if len(h) > 0 and h[len(h) - 1] == 46:
        h = h[: len(h) - 1]
    if len(h) == 0:
        return False
    var ip = parse_ip(h)
    if len(ip) > 0:
        for ref a in c.ips:
            if same(a, ip):
                return True
        return False
    for i in range(len(h)):
        var ch = h[i]
        if not ((ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 45 or ch == 46 or ch == 95):
            return False
    var lh = _lower(h)
    for ref p in c.dns:
        var lp = _lower(view(p))
        if same(lp, lh) or _wild_match(lp, lh):
            return True
    return False


# ---------------------------------------------------------------- path rules
def _dns_under(name: List[UInt8], base: List[UInt8]) -> Bool:
    """RFC 5280 4.2.1.10 DNS constraint: `name` is `base` or a subdomain of it (a leading dot means subdomains only)."""
    var n = List[UInt8]()
    for i in range(2 if len(name) > 2 and name[0] == 42 and name[1] == 46 else 0, len(name)):
        n.append(name[i])
    if len(base) == 0:
        return True
    if base[0] == 46:
        return _ends_with(n, base)
    if same(n, base):
        return True
    var dotted = List[UInt8]()
    dotted.append(46)
    dotted.extend(base.copy())
    return _ends_with(n, dotted)


def _ip_in(ip: List[UInt8], c: List[UInt8]) -> Bool:
    var w = len(c) // 2
    if len(ip) != w:
        return False
    for i in range(w):
        if (ip[i] & c[w + i]) != (c[i] & c[w + i]):
            return False
    return True


def _one_label_below(e: List[UInt8], base: List[UInt8]) -> Bool:
    """`e` is `x.base` for a single non-empty label x."""
    var k = len(e) - len(base) - 1
    if k < 1 or e[k] != 46 or not _ends_with(e, base):
        return False
    for i in range(k):
        if e[i] == 46:
            return False
    return True


def _bad_name(n: List[UInt8]) -> Bool:
    """Empty label (leading, trailing or doubled dot) after an optional `*.` prefix."""
    var i = 2 if len(n) > 2 and n[0] == 42 and n[1] == 46 else 0
    if i >= len(n) or n[i] == 46 or n[len(n) - 1] == 46:
        return True
    for j in range(i + 1, len(n)):
        if n[j] == 46 and n[j - 1] == 46:
            return True
    return False


def _constrain(ca: Certificate, x: Certificate) raises:
    """Every name in `x` must satisfy the name constraints of `ca`."""
    if (ca.nc_unsup & (x.san_types | 0x10)) != 0:
        raise Error("tls: x509: name constraint of a type this verifier cannot check")
    for ref n in x.dns:
        var ln = _lower(view(n))
        if _bad_name(ln):
            raise Error("tls: x509: malformed dns name under name constraints")
        var ok = not ca.has_perm_dns
        for ref b in ca.perm_dns:
            if _dns_under(ln, _lower(view(b))):
                ok = True
        var wild = len(ln) > 2 and ln[0] == 42 and ln[1] == 46
        var stem = List[UInt8]()
        for i in range(2 if wild else 0, len(ln)):
            stem.append(ln[i])
        for ref b in ca.excl_dns:
            var lb = _lower(view(b))
            # a wildcard also covers every one-label child of its stem (CVE-2025-61727)
            if _dns_under(ln, lb) or (wild and _one_label_below(lb, stem)):
                ok = False
        if not ok:
            raise Error("tls: x509: dns name violates name constraints")
    for ref a in x.ips:
        var ok = not ca.has_perm_ip
        for ref b in ca.perm_ip:
            if _ip_in(a, b):
                ok = True
        for ref b in ca.excl_ip:
            if _ip_in(a, b):
                ok = False
        if not ok:
            raise Error("tls: x509: ip address violates name constraints")


def _valid_at(c: Certificate, now: Int) raises:
    if now < c.not_before:
        raise Error("tls: x509: certificate is not yet valid")
    if now > c.not_after:
        raise Error("tls: x509: certificate has expired")


def _ca_rules(c: Certificate, below: Int, anchor: Bool) raises:
    """`below` = intermediates between `c` and the leaf. An anchor without basicConstraints (v1 root) is allowed."""
    if len(c.subject()) <= 2:
        raise Error("tls: x509: CA with an empty subject")
    if c.has_bc or not anchor:
        if not (c.has_bc and c.is_ca):
            raise Error("tls: x509: issuer is not a CA")
    if c.has_ku and (c.ku & KU_KEY_CERT_SIGN) == 0:
        raise Error("tls: x509: CA key usage lacks keyCertSign")
    if c.path_len >= 0 and below > c.path_len:
        raise Error("tls: x509: path length constraint exceeded")
    if not anchor and c.has_eku and not c.eku_server:
        raise Error("tls: x509: CA extended key usage excludes serverAuth")


def _check_path(chain: List[Certificate], below: List[Int], root: Certificate, now: Int) raises:
    """`below` indexes chain: leaf first, then intermediates up to the one the root signed."""
    var k = len(below)
    if k > 0:
        ref leaf = chain[below[0]]
        if leaf.has_eku and not leaf.eku_server:
            raise Error("tls: x509: leaf extended key usage excludes serverAuth")
        if leaf.has_ku and (leaf.ku & KU_DIGITAL_SIGNATURE) == 0:
            raise Error("tls: x509: leaf key usage lacks digitalSignature")
        if leaf.key_kind == KEY_OTHER or (leaf.key_kind == KEY_RSA and rsa_bits(leaf.key_a) < MIN_RSA_BITS):
            raise Error("tls: x509: leaf key is not P-256, P-384 or RSA of at least 2048 bits")
    var nsi = 0  # intermediates seen so far that are not self-issued (RFC 5280 6.1.4 l)
    for p in range(k):
        ref c = chain[below[p]]
        _valid_at(c, now)
        if c.unknown_critical:
            raise Error("tls: x509: unknown critical extension")
        if c.has_ku and ((c.ku & KU_KEY_CERT_SIGN) != 0) != c.is_ca:
            raise Error("tls: x509: keyCertSign and basicConstraints cA disagree")
        if p > 0:
            _ca_rules(c, nsi, False)
            for q in range(p):
                if q == 0 or not chain[below[q]].self_issued():  # name constraints skip self-issued intermediates
                    _constrain(c, chain[below[q]])
            if not c.self_issued():
                nsi += 1
    _valid_at(root, now)
    if k > 0:
        _ca_rules(root, nsi, True)
    for q in range(k):
        if q == 0 or not chain[below[q]].self_issued():
            _constrain(root, chain[below[q]])
    if k > 0:
        verify_sig(chain[below[k - 1]], root)
    for p in range(k - 1, 0, -1):
        verify_sig(chain[below[p - 1]], chain[below[p]])


def _find(
    chain: List[Certificate], roots: List[Certificate], mut path: List[Int], now: Int, mut budget: Int, mut err: String
) -> Bool:
    ref cur = chain[path[len(path) - 1]]
    for j in range(len(roots)):
        ref r = roots[j]
        var below = path.copy()
        if same(cur.raw, r.raw):
            _ = below.pop()
        elif not same(cur.issuer(), r.subject()):
            continue
        if budget <= 0:
            err = "tls: x509: too many candidate paths"
            return False
        budget -= 1
        try:
            _check_path(chain, below, r, now)
            return True
        except e:
            if err.startswith("tls: x509: no path"):
                err = String(e)  # keep the first reason
    for i in range(len(chain)):
        var seen = False
        for q in path:
            if q == i:
                seen = True
        if not seen and same(cur.issuer(), chain[i].subject()):
            path.append(i)
            if _find(chain, roots, path, now, budget, err):
                return True
            _ = path.pop()
    return False


def verify_chain(chain: List[Certificate], host: String, now: Int, roots: List[Certificate]) raises:
    """Raises unless `chain` (leaf first, at most 10 certificates) leads to one of `roots` and is valid for `host`
    at `now` (epoch seconds). The peer may add or omit the root and may order the intermediates freely."""
    if len(chain) == 0 or len(chain) > MAX_CHAIN:
        raise Error("tls: x509: bad chain length")
    if not host_matches(chain[0], view(host.as_bytes())):
        raise Error("tls: x509: certificate is not valid for the host name")
    var path = List[Int]()
    path.append(0)
    var budget = MAX_SIG_ATTEMPTS
    var err = String("tls: x509: no path to a trusted root")
    if not _find(chain, roots, path, now, budget, err):
        raise Error(err)


# ---------------------------------------------------------------- roots
def load_roots_pem(text: Bytes, mut dropped: Int) -> List[Certificate]:
    """Parse every CERTIFICATE block; `dropped` counts the blocks that could not be parsed."""
    var roots = List[Certificate]()
    for ref sp in pem_spans(text):
        if not same(sp[0], "CERTIFICATE".as_bytes()):
            continue
        try:
            roots.append(Certificate.parse(b64_decode(sp[1])))
        except:
            dropped += 1
    return roots^


def load_system_roots() raises -> List[Certificate]:
    """Roots from the first readable system bundle. Prints the count of unparseable blocks to stderr."""
    var paths = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"]
    for p in paths:
        try:
            var raw: List[UInt8]
            with open(p, "r") as f:
                raw = f.read_bytes()
            var dropped = 0
            var r = load_roots_pem(view(raw), dropped)
            if dropped > 0:
                print("tls:", dropped, "system roots could not be parsed and were skipped", file=stderr)
            _ = len(raw)
            return r^
        except:
            pass
    raise Error("tls: no system root bundle found")
