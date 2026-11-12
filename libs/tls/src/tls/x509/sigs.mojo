# Certificate signature verification: picks the hash and padding from the certificate's own algorithm and checks
# it with the issuer's key. SHA-1 and unknown algorithms are refused. Calls the lane 1-2 primitives; today those
# are the vendored ones in shim/ (swap the three imports below at integration).
from tls.x509.cert import *
from tls.x509.der import Der, Bytes, view, copy_of
from tls.x509.shim.hash import sha256, sha384, sha512
from tls.x509.shim.rsa import rsa_pkcs1_verify, rsa_pss_verify
import tls.x509.shim.ec_ct as ct

comptime MIN_RSA_BITS = 2048


def rsa_bits(n: List[UInt8]) -> Int:
    if len(n) == 0:
        return 0
    var top = Int(n[0])
    var b = 0
    while top > 0:
        b += 1
        top >>= 1
    return (len(n) - 1) * 8 + b


def verify_sig(c: Certificate, issuer: Certificate) raises:
    """Raises unless `c` carries a valid signature by `issuer`'s key."""
    var a = c.sig_alg
    var hid = 0  # 0 sha256, 1 sha384, 2 sha512
    if a == SIG_RSA_SHA256 or a == SIG_ECDSA_SHA256 or a == SIG_PSS_SHA256:
        hid = 0
    elif a == SIG_RSA_SHA384 or a == SIG_ECDSA_SHA384 or a == SIG_PSS_SHA384:
        hid = 1
    elif a == SIG_RSA_SHA512 or a == SIG_ECDSA_SHA512 or a == SIG_PSS_SHA512:
        hid = 2
    elif a == SIG_RSA_SHA1 or a == SIG_ECDSA_SHA1:
        raise Error("tls: x509: sha1 signature refused")
    else:
        raise Error("tls: x509: unsupported signature algorithm")
    var tbs = copy_of(c.tbs())
    var h = sha256(tbs) if hid == 0 else (sha384(tbs) if hid == 1 else sha512(tbs))
    var sig = copy_of(c.signature())
    var ecdsa = a >= SIG_ECDSA_SHA256 and a <= SIG_ECDSA_SHA512
    if not ecdsa:
        if issuer.key_kind != KEY_RSA or rsa_bits(issuer.key_a) < MIN_RSA_BITS:
            raise Error("tls: x509: issuer key is not RSA of at least 2048 bits")
        if a >= SIG_PSS_SHA256:
            rsa_pss_verify(issuer.key_a, issuer.key_b, h, sig, c.pss_salt)
        else:
            rsa_pkcs1_verify(issuer.key_a, issuer.key_b, h, sig)
        return
    var sd = Der(view(sig))
    var s = sd.seq()
    sd.end()
    var r = copy_of(s.int_bytes())
    var ss = copy_of(s.int_bytes())
    s.end()
    if issuer.key_kind == KEY_P256:
        ct.ecdsa_verify(ct.p256_curve(), issuer.key_a, h, r, ss, "p256")
    elif issuer.key_kind == KEY_P384:
        ct.ecdsa_verify(ct.p384_curve(), issuer.key_a, h, r, ss, "p384")
    else:
        raise Error("tls: x509: issuer key is not P-256 or P-384")
    _ = len(sig)
