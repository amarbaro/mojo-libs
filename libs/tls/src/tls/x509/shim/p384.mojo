# Ported from Mosaad-M/tls (MIT, (c) Mosaad-M). Temporary stand-in for lanes 1-2 (src/tls/sym, src/tls/asym); import paths rewritten only.
# ============================================================================
# p384.mojo — NIST P-384 elliptic curve
# ============================================================================
# Provides:
#   p384_ecdsa_verify(pub, hash, r, s) → raises on invalid signature
#   p384_public_key(private_key)       → 97-byte uncompressed public key
#   p384_ecdh(private_key, peer_pub)   → 48-byte shared secret (x-coord)
#
# All curve arithmetic runs in crypto/ec_ct.mojo (64-bit Montgomery limbs):
# constant time for secret scalars (public key, ECDH); signature
# verification (ct.ecdsa_verify) sees only public data. The BigInt field
# code left here validates peer public keys for ECDH.
# ============================================================================

import tls.x509.shim.ec_ct as ct
from tls.x509.shim.bigint import (
    BigInt, bigint_zero, bigint_one, bigint_from_u64, bigint_from_bytes,
    bigint_to_bytes, bigint_is_zero, bigint_cmp, bigint_add, bigint_sub,
    bigint_mul, bigint_mod, bigint_modmul, bigint_modinv,
    bigint_bit_len, bigint_get_bit, bigint_cswap_inplace,
)


# ============================================================================
# P-384 constants (returned as BigInt on demand)
# ============================================================================

def _p384_p() -> BigInt:
    """Field prime p = 2^384 − 2^128 − 2^96 + 2^32 − 1."""
    var b = List[UInt8](capacity=48)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFE)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    b.append(0x00); b.append(0x00); b.append(0x00); b.append(0x00)
    b.append(0x00); b.append(0x00); b.append(0x00); b.append(0x00)
    b.append(0xFF); b.append(0xFF); b.append(0xFF); b.append(0xFF)
    return bigint_from_bytes(b)


# ============================================================================
# Field arithmetic — all operands in [0, p-1]
# ============================================================================

def _p384_fadd(a: BigInt, b: BigInt, p: BigInt) -> BigInt:
    """(a + b) mod p."""
    var r = bigint_add(a, b)
    if bigint_cmp(r, p) >= 0:
        r = bigint_sub(r, p)
    return r^


def _p384_fsub(a: BigInt, b: BigInt, p: BigInt) -> BigInt:
    """(a - b) mod p."""
    if bigint_cmp(a, b) >= 0:
        return bigint_sub(a, b)
    return bigint_sub(bigint_add(a, p), b)


def _p384_nist_reduce(t: BigInt) -> BigInt:
    """Reduce a 768-bit product mod P-384 prime using NIST FIPS 186-4 D.1.2.4.

    t must be < p^2 (true for products of field elements).
    Words c[0..23] are the 32-bit LE limbs of t (c[0]=LSW).
    Result is in [0, p).

    Per-word linear combination derived from 2^{32k} mod p for k=12..23:
      2^384 ≡ 2^128 + 2^96 - 2^32 + 1  (mod p)
    """
    var nt = len(t.limbs)
    var c0:  Int64 = Int64(t.limbs[0])  if nt >  0 else 0
    var c1:  Int64 = Int64(t.limbs[1])  if nt >  1 else 0
    var c2:  Int64 = Int64(t.limbs[2])  if nt >  2 else 0
    var c3:  Int64 = Int64(t.limbs[3])  if nt >  3 else 0
    var c4:  Int64 = Int64(t.limbs[4])  if nt >  4 else 0
    var c5:  Int64 = Int64(t.limbs[5])  if nt >  5 else 0
    var c6:  Int64 = Int64(t.limbs[6])  if nt >  6 else 0
    var c7:  Int64 = Int64(t.limbs[7])  if nt >  7 else 0
    var c8:  Int64 = Int64(t.limbs[8])  if nt >  8 else 0
    var c9:  Int64 = Int64(t.limbs[9])  if nt >  9 else 0
    var c10: Int64 = Int64(t.limbs[10]) if nt > 10 else 0
    var c11: Int64 = Int64(t.limbs[11]) if nt > 11 else 0
    var c12: Int64 = Int64(t.limbs[12]) if nt > 12 else 0
    var c13: Int64 = Int64(t.limbs[13]) if nt > 13 else 0
    var c14: Int64 = Int64(t.limbs[14]) if nt > 14 else 0
    var c15: Int64 = Int64(t.limbs[15]) if nt > 15 else 0
    var c16: Int64 = Int64(t.limbs[16]) if nt > 16 else 0
    var c17: Int64 = Int64(t.limbs[17]) if nt > 17 else 0
    var c18: Int64 = Int64(t.limbs[18]) if nt > 18 else 0
    var c19: Int64 = Int64(t.limbs[19]) if nt > 19 else 0
    var c20: Int64 = Int64(t.limbs[20]) if nt > 20 else 0
    var c21: Int64 = Int64(t.limbs[21]) if nt > 21 else 0
    var c22: Int64 = Int64(t.limbs[22]) if nt > 22 else 0
    var c23: Int64 = Int64(t.limbs[23]) if nt > 23 else 0

    # Signed 12-word accumulators.  Coefficients from r[k] = 2^{32k} mod p:
    var a0  = c0  + c12 + c20 + c21 - c23
    var a1  = c1  - c12 + c13 - c20 + c22 + c23
    var a2  = c2  - c13 + c14 - c21 + c23
    var a3  = c3  + c12 - c14 + c15 + c20 + c21 - c22 - c23
    var a4  = c4  + c12 + c13 - c15 + c16 + c20 + 2*c21 + c22 - 2*c23
    var a5  = c5  + c13 + c14 - c16 + c17 + c21 + 2*c22 + c23
    var a6  = c6  + c14 + c15 - c17 + c18 + c22 + 2*c23
    var a7  = c7  + c15 + c16 - c18 + c19 + c23
    var a8  = c8  + c16 + c17 - c19 + c20
    var a9  = c9  + c17 + c18 - c20 + c21
    var a10 = c10 + c18 + c19 - c21 + c22
    var a11 = c11 + c19 + c20 - c22 + c23

    # First carry propagation
    var carry: Int64
    carry = a0  >> 32; a0  &= Int64(0xFFFFFFFF); a1  += carry
    carry = a1  >> 32; a1  &= Int64(0xFFFFFFFF); a2  += carry
    carry = a2  >> 32; a2  &= Int64(0xFFFFFFFF); a3  += carry
    carry = a3  >> 32; a3  &= Int64(0xFFFFFFFF); a4  += carry
    carry = a4  >> 32; a4  &= Int64(0xFFFFFFFF); a5  += carry
    carry = a5  >> 32; a5  &= Int64(0xFFFFFFFF); a6  += carry
    carry = a6  >> 32; a6  &= Int64(0xFFFFFFFF); a7  += carry
    carry = a7  >> 32; a7  &= Int64(0xFFFFFFFF); a8  += carry
    carry = a8  >> 32; a8  &= Int64(0xFFFFFFFF); a9  += carry
    carry = a9  >> 32; a9  &= Int64(0xFFFFFFFF); a10 += carry
    carry = a10 >> 32; a10 &= Int64(0xFFFFFFFF); a11 += carry
    var a12 = a11 >> 32; a11 &= Int64(0xFFFFFFFF)

    # Reduce a12 * 2^384: 2^384 ≡ 2^128 + 2^96 - 2^32 + 1 mod p
    # In 12-word LE: word0=+1, word1=-1, word3=+1, word4=+1
    a0  += a12
    a1  -= a12
    a3  += a12
    a4  += a12

    # Second carry propagation
    carry = a0  >> 32; a0  &= Int64(0xFFFFFFFF); a1  += carry
    carry = a1  >> 32; a1  &= Int64(0xFFFFFFFF); a2  += carry
    carry = a2  >> 32; a2  &= Int64(0xFFFFFFFF); a3  += carry
    carry = a3  >> 32; a3  &= Int64(0xFFFFFFFF); a4  += carry
    carry = a4  >> 32; a4  &= Int64(0xFFFFFFFF); a5  += carry
    carry = a5  >> 32; a5  &= Int64(0xFFFFFFFF); a6  += carry
    carry = a6  >> 32; a6  &= Int64(0xFFFFFFFF); a7  += carry
    carry = a7  >> 32; a7  &= Int64(0xFFFFFFFF); a8  += carry
    carry = a8  >> 32; a8  &= Int64(0xFFFFFFFF); a9  += carry
    carry = a9  >> 32; a9  &= Int64(0xFFFFFFFF); a10 += carry
    carry = a10 >> 32; a10 &= Int64(0xFFFFFFFF); a11 += carry
    a12 = a11 >> 32; a11 &= Int64(0xFFFFFFFF)

    # a12 should be 0 or 1 — one more reduction for safety
    a0  += a12
    a1  -= a12
    a3  += a12
    a4  += a12

    # Third carry propagation
    carry = a0  >> 32; a0  &= Int64(0xFFFFFFFF); a1  += carry
    carry = a1  >> 32; a1  &= Int64(0xFFFFFFFF); a2  += carry
    carry = a2  >> 32; a2  &= Int64(0xFFFFFFFF); a3  += carry
    carry = a3  >> 32; a3  &= Int64(0xFFFFFFFF); a4  += carry
    carry = a4  >> 32; a4  &= Int64(0xFFFFFFFF); a5  += carry
    carry = a5  >> 32; a5  &= Int64(0xFFFFFFFF); a6  += carry
    carry = a6  >> 32; a6  &= Int64(0xFFFFFFFF); a7  += carry
    carry = a7  >> 32; a7  &= Int64(0xFFFFFFFF); a8  += carry
    carry = a8  >> 32; a8  &= Int64(0xFFFFFFFF); a9  += carry
    carry = a9  >> 32; a9  &= Int64(0xFFFFFFFF); a10 += carry
    carry = a10 >> 32; a10 &= Int64(0xFFFFFFFF); a11 += carry
    a11 &= Int64(0xFFFFFFFF)

    # Build 12-limb BigInt, trim leading zeros
    var r = BigInt()
    r.limbs = List[UInt32](capacity=12)
    r.limbs.append(UInt32(a0));  r.limbs.append(UInt32(a1))
    r.limbs.append(UInt32(a2));  r.limbs.append(UInt32(a3))
    r.limbs.append(UInt32(a4));  r.limbs.append(UInt32(a5))
    r.limbs.append(UInt32(a6));  r.limbs.append(UInt32(a7))
    r.limbs.append(UInt32(a8));  r.limbs.append(UInt32(a9))
    r.limbs.append(UInt32(a10)); r.limbs.append(UInt32(a11))
    while len(r.limbs) > 1 and r.limbs[len(r.limbs) - 1] == 0:
        _ = r.limbs.pop()

    var p = _p384_p()
    for _ in range(3):
        if bigint_cmp(r, p) >= 0:
            r = bigint_sub(r, p)
    return r^


def _p384_fmul_fast(a: BigInt, b: BigInt) -> BigInt:
    """(a * b) mod p384 using NIST fast reduction."""
    return _p384_nist_reduce(bigint_mul(a, b))


def _p384_fsq_fast(a: BigInt) -> BigInt:
    """a^2 mod p384 using NIST fast reduction."""
    return _p384_nist_reduce(bigint_mul(a, a.copy()))


def _p384_fmul(a: BigInt, b: BigInt, p: BigInt) -> BigInt:
    """(a * b) mod p."""
    return _p384_fmul_fast(a, b)


def _p384_fsq(a: BigInt, p: BigInt) -> BigInt:
    """a^2 mod p."""
    return _p384_fsq_fast(a)


def _p384_fk(a: BigInt, k: UInt64, p: BigInt) -> BigInt:
    """k*a mod p for small constant k using repeated doubling."""
    if k == 2:
        return _p384_fadd(a, a.copy(), p)
    elif k == 3:
        var a2 = _p384_fadd(a.copy(), a.copy(), p)
        return _p384_fadd(a2, a, p)
    elif k == 4:
        var a2 = _p384_fadd(a.copy(), a.copy(), p)
        return _p384_fadd(a2, a2.copy(), p)
    elif k == 8:
        var a2 = _p384_fadd(a.copy(), a.copy(), p)
        var a4 = _p384_fadd(a2, a2.copy(), p)
        return _p384_fadd(a4, a4.copy(), p)
    else:
        return bigint_modmul(a, bigint_from_u64(k), p)


# ============================================================================
# Jacobian point representation
# ============================================================================

# ============================================================================
# Point doubling — dbl-2001-b (optimized for a = -3)
# P-384 also has a = -3, so the same formula applies.
# ============================================================================

# ============================================================================
# Mixed addition (Jacobian P + affine Q) — madd-2007-bl
# ============================================================================

# ============================================================================
# Full Jacobian addition
# ============================================================================

# ============================================================================
# Scalar multiplication: Montgomery ladder (constant-time structure)
# ============================================================================

# ============================================================================
# Point validation
# ============================================================================

def _p384_point_on_curve(x: BigInt, y: BigInt, p: BigInt) -> Bool:
    """Check y² ≡ x³ − 3x + b (mod p) for P-384."""
    # b = b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875a
    #       c656398d8a2ed19d2a85c8edd3ec2aef
    var bv = List[UInt8](capacity=48)
    bv.append(0xB3); bv.append(0x31); bv.append(0x2F); bv.append(0xA7)
    bv.append(0xE2); bv.append(0x3E); bv.append(0xE7); bv.append(0xE4)
    bv.append(0x98); bv.append(0x8E); bv.append(0x05); bv.append(0x6B)
    bv.append(0xE3); bv.append(0xF8); bv.append(0x2D); bv.append(0x19)
    bv.append(0x18); bv.append(0x1D); bv.append(0x9C); bv.append(0x6E)
    bv.append(0xFE); bv.append(0x81); bv.append(0x41); bv.append(0x12)
    bv.append(0x03); bv.append(0x14); bv.append(0x08); bv.append(0x8F)
    bv.append(0x50); bv.append(0x13); bv.append(0x87); bv.append(0x5A)
    bv.append(0xC6); bv.append(0x56); bv.append(0x39); bv.append(0x8D)
    bv.append(0x8A); bv.append(0x2E); bv.append(0xD1); bv.append(0x9D)
    bv.append(0x2A); bv.append(0x85); bv.append(0xC8); bv.append(0xED)
    bv.append(0xD3); bv.append(0xEC); bv.append(0x2A); bv.append(0xEF)
    var b   = bigint_from_bytes(bv)
    var lhs = _p384_fsq(y, p)
    var x3  = _p384_fmul(_p384_fsq(x.copy(), p), x.copy(), p)
    var ax  = _p384_fk(x, 3, p)
    var rhs = _p384_fadd(_p384_fsub(x3, ax, p), b, p)
    return bigint_cmp(lhs, rhs) == 0


# ============================================================================
# Parse uncompressed public key (97 bytes: 0x04 || X || Y)
# ============================================================================

def _p384_parse_pub(pub: List[UInt8]) raises -> Tuple[BigInt, BigInt]:
    """Parse 97-byte uncompressed P-384 public key → (Qx, Qy)."""
    if len(pub) != 97 or pub[0] != 0x04:
        raise Error("p384: invalid public key format (need 97-byte uncompressed)")
    var qx_bytes = List[UInt8](capacity=48)
    var qy_bytes = List[UInt8](capacity=48)
    for i in range(48):
        qx_bytes.append(pub[1 + i])
        qy_bytes.append(pub[49 + i])
    return (bigint_from_bytes(qx_bytes), bigint_from_bytes(qy_bytes))


# ============================================================================
# Public API
# ============================================================================

def p384_public_key(private_key: List[UInt8]) raises -> List[UInt8]:
    """Derive the 97-byte uncompressed P-384 public key from a 48-byte scalar
    in [1, n-1]. Constant time in the private key (crypto/ec_ct.mojo)."""
    if len(private_key) != 48:
        raise Error("p384: private key must be 48 bytes")
    return ct.public_key(private_key, ct.p384_curve())


def p384_ecdh(private_key: List[UInt8], peer_public_key: List[UInt8]) raises -> List[UInt8]:
    """48-byte P-384 ECDH shared secret (x-coordinate).

    The peer key is validated (format, coordinates < p, on the curve) with
    the BigInt code, since it is public; the scalar multiplication by the
    private key is constant time (crypto/ec_ct.mojo).
    """
    if len(private_key) != 48:
        raise Error("p384: private key must be 48 bytes")
    var p = _p384_p()
    var parsed = _p384_parse_pub(peer_public_key)
    var qx = parsed[0].copy()
    var qy = parsed[1].copy()
    if bigint_cmp(qx, p) >= 0 or bigint_cmp(qy, p) >= 0:
        raise Error("p384: peer public key coordinate out of range")
    if not _p384_point_on_curve(qx.copy(), qy.copy(), p):
        raise Error("p384: peer public key not on curve")
    return ct.ecdh_x(private_key, peer_public_key, ct.p384_curve())


def p384_ecdsa_verify(
    pub_key:  List[UInt8],   # 97-byte uncompressed P-384 public key
    msg_hash: List[UInt8],   # 48-byte message hash (SHA-384)
    sig_r:    List[UInt8],   # up to 48-byte r component
    sig_s:    List[UInt8],   # up to 48-byte s component
) raises:
    """Verify P-384 ECDSA signature. Raises on invalid."""
    ct.ecdsa_verify(ct.p384_curve(), pub_key, msg_hash, sig_r, sig_s, "p384")
