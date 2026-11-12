"""ChaCha20 (RFC 8439 2.4), Poly1305 (2.5) and their AEAD (2.8), in place.

ChaCha20 keeps each state word as a SIMD vector whose lane j belongs to block j, so the rounds are the scalar
code on vectors (add, xor, rotate: constant time, no intrinsics). Poly1305 is radix 2^26 on 64-bit products
with a mask-selected final reduction. open() verifies the tag over the ciphertext before it decrypts.
"""
from std.bit import rotate_bits_left
from std.math import iota
from std.memory import bitcast
from tls.sym.aead import Aead

comptime U32 = DType.uint32


@always_inline
def _qr[W: Int, a: Int, b: Int, c: Int, d: Int](mut x: Array[SIMD[U32, W], 16]):
    x[a] += x[b]
    x[d] = rotate_bits_left[16](x[d] ^ x[a])
    x[c] += x[d]
    x[b] = rotate_bits_left[12](x[b] ^ x[c])
    x[a] += x[b]
    x[d] = rotate_bits_left[8](x[d] ^ x[a])
    x[c] += x[d]
    x[b] = rotate_bits_left[7](x[b] ^ x[c])


def _keystream[W: Int, o: MutOrigin](k: SIMD[U32, 8], n: SIMD[U32, 4], ctr: UInt32, ks: Pointer[UInt32, o]):
    """Blocks ctr .. ctr+W-1 into ks, block j at ks[16j .. 16j+16]."""
    comptime V = SIMD[U32, W]
    var x = Array[V, 16](fill=V(0))
    x[0] = V(0x61707865)
    x[1] = V(0x3320646E)
    x[2] = V(0x79622D32)
    x[3] = V(0x6B206574)
    comptime for i in range(8):
        x[4 + i] = V(k[i])
    x[12] = V(ctr) + iota[U32, W]()
    x[13] = V(n[0])
    x[14] = V(n[1])
    x[15] = V(n[2])
    var init = x.copy()
    for _ in range(10):
        _qr[W, 0, 4, 8, 12](x)
        _qr[W, 1, 5, 9, 13](x)
        _qr[W, 2, 6, 10, 14](x)
        _qr[W, 3, 7, 11, 15](x)
        _qr[W, 0, 5, 10, 15](x)
        _qr[W, 1, 6, 11, 12](x)
        _qr[W, 2, 7, 8, 13](x)
        _qr[W, 3, 4, 9, 14](x)
    comptime for i in range(16):
        ks.unsafe_offset(i).unsafe_strided_store[width=W](x[i] + init[i], 16)


def chacha20_xor[o: MutOrigin](key: SIMD[U32, 8], nonce: SIMD[U32, 4], ctr: UInt32, p: Pointer[UInt8, o], n: Int):
    """XOR n bytes at p with the keystream starting at block ctr (nonce lane 3 unused). Counter wraps mod 2^32."""
    var ks = Array[UInt32, 256](fill=0)
    var off = 0
    var c = ctr
    while off + 1024 <= n:
        _keystream[16](key, nonce, c, ks.unsafe_ptr())
        for j in range(0, 1024, 64):
            var q = p.unsafe_offset(off + j)
            q.unsafe_store(0, q.unsafe_load[width=64]() ^ ks.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_offset(j).unsafe_load[width=64]())
        off += 1024
        c += 16
    while off < n:
        _keystream[4](key, nonce, c, ks.unsafe_ptr())
        var kb = ks.unsafe_ptr().unsafe_bitcast[UInt8]()
        for j in range(min(256, n - off)):
            p[unsafe_offset=off + j] ^= kb[unsafe_offset=j]
        off += 256
        c += 4


def _words[n: Int](s: Span[UInt8, _]) -> SIMD[U32, n]:
    var w = SIMD[U32, n](0)
    for i in range(len(s) // 4):
        w[i] = UInt32(s[4 * i]) | (UInt32(s[4 * i + 1]) << 8) | (UInt32(s[4 * i + 2]) << 16) | (UInt32(s[4 * i + 3]) << 24)
    return w


struct Poly1305:
    var h: Array[UInt64, 5]
    var r: Array[UInt64, 5]
    var pad: SIMD[U32, 4]

    def __init__(out self, t: SIMD[U32, 8]):
        self.pad = SIMD[U32, 4](t[4], t[5], t[6], t[7])
        self.h = Array[UInt64, 5](fill=0)
        var r = SIMD[DType.uint64, 4](UInt64(t[0]), UInt64(t[1]), UInt64(t[2]), UInt64(t[3]))
        self.r = Array[UInt64, 5](fill=0)
        self.r[0] = r[0] & 0x3FFFFFF
        self.r[1] = ((r[0] >> 26) | (r[1] << 6)) & 0x3FFFF03
        self.r[2] = ((r[1] >> 20) | (r[2] << 12)) & 0x3FFC0FF
        self.r[3] = ((r[2] >> 14) | (r[3] << 18)) & 0x3F03FFF
        self.r[4] = (r[3] >> 8) & 0x00FFFFF

    def blocks(mut self, p: Pointer[UInt8, _], n: Int, hibit: UInt64):
        """Absorb n bytes (a multiple of 16); hibit is 1 << 24 for a full block, 0 for the 0x01-terminated tail."""
        var s1 = self.r[1] * 5
        var s2 = self.r[2] * 5
        var s3 = self.r[3] * 5
        var s4 = self.r[4] * 5
        var h0 = self.h[0]
        var h1 = self.h[1]
        var h2 = self.h[2]
        var h3 = self.h[3]
        var h4 = self.h[4]
        var r0 = self.r[0]
        var r1 = self.r[1]
        var r2 = self.r[2]
        var r3 = self.r[3]
        var r4 = self.r[4]
        for off in range(0, n, 16):
            var m = p.unsafe_offset(off).unsafe_bitcast[UInt32]()
            var t0 = UInt64(m.unsafe_load[width=1, alignment=1]())
            var t1 = UInt64(m.unsafe_offset(1).unsafe_load[width=1, alignment=1]())
            var t2 = UInt64(m.unsafe_offset(2).unsafe_load[width=1, alignment=1]())
            var t3 = UInt64(m.unsafe_offset(3).unsafe_load[width=1, alignment=1]())
            h0 += t0 & 0x3FFFFFF
            h1 += ((t0 >> 26) | (t1 << 6)) & 0x3FFFFFF
            h2 += ((t1 >> 20) | (t2 << 12)) & 0x3FFFFFF
            h3 += ((t2 >> 14) | (t3 << 18)) & 0x3FFFFFF
            h4 += (t3 >> 8) | hibit
            var d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
            d1 += d0 >> 26
            d2 += d1 >> 26
            d3 += d2 >> 26
            d4 += d3 >> 26
            h0 = (d0 & 0x3FFFFFF) + (d4 >> 26) * 5
            h1 = d1 & 0x3FFFFFF
            h2 = d2 & 0x3FFFFFF
            h3 = d3 & 0x3FFFFFF
            h4 = d4 & 0x3FFFFFF
            h1 += h0 >> 26
            h0 &= 0x3FFFFFF
        self.h[0] = h0
        self.h[1] = h1
        self.h[2] = h2
        self.h[3] = h3
        self.h[4] = h4

    def padded(mut self, p: Pointer[UInt8, _], n: Int):
        """AEAD segment: the data, zero padded to a multiple of 16, every block a full block."""
        self.blocks(p, n - n % 16, 1 << 24)
        if n % 16 != 0:
            var t = Array[UInt8, 16](fill=0)
            for i in range(n % 16):
                t[i] = p[unsafe_offset=n - n % 16 + i]
            self.blocks(t.unsafe_ptr(), 16, 1 << 24)

    def tag(self) -> SIMD[U32, 4]:
        """Fully carry, subtract p when h >= p (mask select, no branch), add the pad mod 2^128."""
        var h0 = self.h[0]
        var h1 = self.h[1]
        var h2 = self.h[2]
        var h3 = self.h[3]
        var h4 = self.h[4]
        h2 += h1 >> 26
        h1 &= 0x3FFFFFF
        h3 += h2 >> 26
        h2 &= 0x3FFFFFF
        h4 += h3 >> 26
        h3 &= 0x3FFFFFF
        h0 += (h4 >> 26) * 5
        h4 &= 0x3FFFFFF
        h1 += h0 >> 26
        h0 &= 0x3FFFFFF
        var g0 = h0 + 5
        var g1 = h1 + (g0 >> 26)
        g0 &= 0x3FFFFFF
        var g2 = h2 + (g1 >> 26)
        g1 &= 0x3FFFFFF
        var g3 = h3 + (g2 >> 26)
        g2 &= 0x3FFFFFF
        var g4 = h4 + (g3 >> 26) - (1 << 26)
        g3 &= 0x3FFFFFF
        var keep = (g4 >> 63) - 1  # all ones when h >= p (g4 did not underflow)
        h0 = (h0 & ~keep) | (g0 & keep)
        h1 = (h1 & ~keep) | (g1 & keep)
        h2 = (h2 & ~keep) | (g2 & keep)
        h3 = (h3 & ~keep) | (g3 & keep)
        h4 = (h4 & ~keep) | (g4 & keep)
        var f0 = ((h0 | (h1 << 26)) & 0xFFFFFFFF) + UInt64(self.pad[0])
        var f1 = (((h1 >> 6) | (h2 << 20)) & 0xFFFFFFFF) + UInt64(self.pad[1]) + (f0 >> 32)
        var f2 = (((h2 >> 12) | (h3 << 14)) & 0xFFFFFFFF) + UInt64(self.pad[2]) + (f1 >> 32)
        var f3 = (((h3 >> 18) | (h4 << 8)) & 0xFFFFFFFF) + UInt64(self.pad[3]) + (f2 >> 32)
        return SIMD[U32, 4](UInt32(f0 & 0xFFFFFFFF), UInt32(f1 & 0xFFFFFFFF), UInt32(f2 & 0xFFFFFFFF), UInt32(f3 & 0xFFFFFFFF))


def poly1305_mac(key: Span[UInt8, _], msg: Span[UInt8, _]) -> SIMD[U32, 4]:
    """The plain RFC 8439 MAC: a short last block is terminated by a 0x01 byte instead of zero padded."""
    var st = Poly1305(_words[8](key))
    var n = len(msg)
    var p = msg.unsafe_ptr()
    st.blocks(p, n - n % 16, 1 << 24)
    if n % 16 != 0:
        var t = Array[UInt8, 16](fill=0)
        for i in range(n % 16):
            t[i] = p[unsafe_offset=n - n % 16 + i]
        t[n % 16] = 1
        st.blocks(t.unsafe_ptr(), 16, 0)
    return st.tag()


struct ChaCha20Poly1305(Aead, Copyable, Movable):
    var key: SIMD[U32, 8]

    def __init__(out self, key: Span[UInt8, _]) raises:
        if len(key) != 32:
            raise Error("tls: chacha20 key must be 32 bytes")
        self.key = _words[8](key)

    def _tag(self, nonce: SIMD[U32, 4], aad: Span[UInt8, _], ct: Pointer[UInt8, _], n: Int) -> SIMD[U32, 4]:
        var ks = Array[UInt32, 16](fill=0)
        _keystream[1](self.key, nonce, 0, ks.unsafe_ptr())  # block 0: its first 32 bytes are the one-time Poly1305 key
        var st = Poly1305(ks.unsafe_ptr().unsafe_load[width=8]())
        st.padded(aad.unsafe_ptr(), len(aad))
        st.padded(ct, n)
        var lens = Array[UInt64, 2](fill=UInt64(len(aad)))
        lens[1] = UInt64(n)
        st.blocks(lens.unsafe_ptr().unsafe_bitcast[UInt8](), 16, 1 << 24)
        return st.tag()

    def _nonce(self, nonce: Span[UInt8, _], n: Int) raises -> SIMD[U32, 4]:
        if len(nonce) != 12 or n < 0 or n > 274877906880:  # 12-byte nonce; plaintext at most 2^32 - 1 blocks
            raise Error("tls: chacha20-poly1305 bad nonce or length")
        return _words[4](nonce)

    def seal(self, nonce: Span[UInt8, ImmutAnyOrigin], aad: Span[UInt8, ImmutAnyOrigin], mut buf: List[UInt8]) raises:
        var n = len(buf)
        var nw = self._nonce(nonce, n)
        var p = buf.unsafe_ptr()
        chacha20_xor(self.key, nw, 1, p, n)
        var t = self._tag(nw, aad, p, n)
        for i in range(16):
            buf.append(UInt8((t[i // 4] >> UInt32(8 * (i % 4))) & 0xFF))

    def open(self, nonce: Span[UInt8, ImmutAnyOrigin], aad: Span[UInt8, ImmutAnyOrigin], mut buf: List[UInt8]) raises:
        var n = len(buf) - 16
        var nw = self._nonce(nonce, n)
        var p = buf.unsafe_ptr()
        var given = _words[4](Span(buf)[n:])
        if (self._tag(nw, aad, p, n) ^ given).reduce_or() != 0:
            raise Error("tls: bad record mac")
        chacha20_xor(self.key, nw, 1, p, n)
        buf.shrink(n)
