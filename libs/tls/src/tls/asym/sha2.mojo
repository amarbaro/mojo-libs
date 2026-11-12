# SHA-256/384/512 and HMAC, only what lane 2 needs (RFC 6979 nonces, PSS MGF1). Interim copy of the lane 1
# interface (docs/api.md: tls.sym sha256/sha384/sha512/hmac): at integration, replace this file by imports from tls.sym.


def _k256() -> List[UInt32]:
    return [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]


def _k512() -> List[UInt64]:
    return [
        0x428A2F98D728AE22, 0x7137449123EF65CD, 0xB5C0FBCFEC4D3B2F, 0xE9B5DBA58189DBBC, 0x3956C25BF348B538,
        0x59F111F1B605D019, 0x923F82A4AF194F9B, 0xAB1C5ED5DA6D8118, 0xD807AA98A3030242, 0x12835B0145706FBE,
        0x243185BE4EE4B28C, 0x550C7DC3D5FFB4E2, 0x72BE5D74F27B896F, 0x80DEB1FE3B1696B1, 0x9BDC06A725C71235,
        0xC19BF174CF692694, 0xE49B69C19EF14AD2, 0xEFBE4786384F25E3, 0x0FC19DC68B8CD5B5, 0x240CA1CC77AC9C65,
        0x2DE92C6F592B0275, 0x4A7484AA6EA6E483, 0x5CB0A9DCBD41FBD4, 0x76F988DA831153B5, 0x983E5152EE66DFAB,
        0xA831C66D2DB43210, 0xB00327C898FB213F, 0xBF597FC7BEEF0EE4, 0xC6E00BF33DA88FC2, 0xD5A79147930AA725,
        0x06CA6351E003826F, 0x142929670A0E6E70, 0x27B70A8546D22FFC, 0x2E1B21385C26C926, 0x4D2C6DFC5AC42AED,
        0x53380D139D95B3DF, 0x650A73548BAF63DE, 0x766A0ABB3C77B2A8, 0x81C2C92E47EDAEE6, 0x92722C851482353B,
        0xA2BFE8A14CF10364, 0xA81A664BBC423001, 0xC24B8B70D0F89791, 0xC76C51A30654BE30, 0xD192E819D6EF5218,
        0xD69906245565A910, 0xF40E35855771202A, 0x106AA07032BBD1B8, 0x19A4C116B8D2D0C8, 0x1E376C085141AB53,
        0x2748774CDF8EEB99, 0x34B0BCB5E19B48A8, 0x391C0CB3C5C95A63, 0x4ED8AA4AE3418ACB, 0x5B9CCA4F7763E373,
        0x682E6FF3D6B2B8A3, 0x748F82EE5DEFB2FC, 0x78A5636F43172F60, 0x84C87814A1F0AB72, 0x8CC702081A6439EC,
        0x90BEFFFA23631E28, 0xA4506CEBDE82BDE9, 0xBEF9A3F7B2C67915, 0xC67178F2E372532B, 0xCA273ECEEA26619C,
        0xD186B8C721C0C207, 0xEADA7DD6CDE0EB1E, 0xF57D4F7FEE6ED178, 0x06F067AA72176FBA, 0x0A637DC5A2C898A6,
        0x113F9804BEF90DAE, 0x1B710B35131C471B, 0x28DB77F523047D84, 0x32CAAB7B40C72493, 0x3C9EBE0A15C9BEBC,
        0x431D67C49C100D4C, 0x4CC5D4BECB3E42B6, 0x597F299CFC657E2A, 0x5FCB6FAB3AD6FAEC, 0x6C44198C4A475817,
    ]


def _h0(alg: Int) -> List[UInt64]:
    if alg == 256:
        return [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    if alg == 384:
        return [0xCBBB9D5DC1059ED8, 0x629A292A367CD507, 0x9159015A3070DD17, 0x152FECD8F70E5939,
                0x67332667FFC00B31, 0x8EB44A8768581511, 0xDB0C2E0D64F98FA7, 0x47B5481DBEFA4FA4]
    return [0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
            0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179]


def _rotr32(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


def _rotr64(x: UInt64, n: UInt64) -> UInt64:
    return (x >> n) | (x << (64 - n))


def _block256(mut h: List[UInt64], p: Span[UInt8, _], k: List[UInt32]):
    var w = List[UInt32](length=64, fill=0)
    for i in range(16):
        w[i] = (UInt32(p[4 * i]) << 24) | (UInt32(p[4 * i + 1]) << 16) | (UInt32(p[4 * i + 2]) << 8) | UInt32(p[4 * i + 3])
    for i in range(16, 64):
        var s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
        var s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var v = List[UInt32](length=8, fill=0)
    for i in range(8):
        v[i] = UInt32(h[i])
    for i in range(64):
        var t1 = v[7] + (_rotr32(v[4], 6) ^ _rotr32(v[4], 11) ^ _rotr32(v[4], 25)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) + k[i] + w[i]
        var t2 = (_rotr32(v[0], 2) ^ _rotr32(v[0], 13) ^ _rotr32(v[0], 22)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]))
        v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] + t1
        v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 + t2
    for i in range(8):
        h[i] = UInt64(UInt32(h[i]) + v[i])


def _block512(mut h: List[UInt64], p: Span[UInt8, _], k: List[UInt64]):
    var w = List[UInt64](length=80, fill=0)
    for i in range(16):
        var x: UInt64 = 0
        for j in range(8):
            x = (x << 8) | UInt64(p[8 * i + j])
        w[i] = x
    for i in range(16, 80):
        var s0 = _rotr64(w[i - 15], 1) ^ _rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
        var s1 = _rotr64(w[i - 2], 19) ^ _rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var v = h.copy()
    for i in range(80):
        var t1 = v[7] + (_rotr64(v[4], 14) ^ _rotr64(v[4], 18) ^ _rotr64(v[4], 41)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) + k[i] + w[i]
        var t2 = (_rotr64(v[0], 28) ^ _rotr64(v[0], 34) ^ _rotr64(v[0], 39)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]))
        v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] + t1
        v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 + t2
    for i in range(8):
        h[i] += v[i]


def sha2(alg: Int, data: Span[UInt8, _]) -> List[UInt8]:
    """SHA-`alg` (256, 384 or 512) of data."""
    var wide = alg != 256
    var bs = 128 if wide else 64
    var m = List[UInt8](data)
    m.append(0x80)
    while (len(m) + (16 if wide else 8)) % bs != 0:
        m.append(0)
    var bits = UInt64(len(data)) * 8
    for _ in range(8 if wide else 0):
        m.append(0)
    for i in range(7, -1, -1):
        m.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))
    var h = _h0(alg)
    if wide:
        var k = _k512()
        for off in range(0, len(m), bs):
            _block512(h, Span(m)[off : off + bs], k)
    else:
        var k = _k256()
        for off in range(0, len(m), bs):
            _block256(h, Span(m)[off : off + bs], k)
    var out = List[UInt8]()
    var wb = 8 if wide else 4
    for i in range(alg // 8 // wb):
        for j in range(wb - 1, -1, -1):
            out.append(UInt8((h[i] >> UInt64(8 * j)) & 0xFF))
    return out^


def hmac(alg: Int, key: Span[UInt8, _], data: Span[UInt8, _]) -> List[UInt8]:
    var bs = 64 if alg == 256 else 128
    var k = sha2(alg, key) if len(key) > bs else List[UInt8](key)
    while len(k) < bs:
        k.append(0)
    var inner = List[UInt8](capacity=bs + len(data))
    var outer = List[UInt8](capacity=bs + alg // 8)
    for i in range(bs):
        inner.append(k[i] ^ 0x36)
        outer.append(k[i] ^ 0x5C)
    inner.extend(data)
    outer.extend(sha2(alg, inner))
    return sha2(alg, outer)
