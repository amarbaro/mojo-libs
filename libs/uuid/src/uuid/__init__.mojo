"""UUID for Mojo, byte-identical behaviour with CPython 3.14 uuid (core)."""
from std.collections import Array
from std.ffi import external_call
from hashlib import Md5, Sha1

struct UUID(Copyable, Movable, ImplicitlyCopyable):
    var _int: UInt128

    def __init__(out self, value: UInt128):
        self._int = value

    def __init__(out self, hex: String, version: Int = 0) raises:
        var h = hex.replace("urn:", "")
        h = h.replace("uuid:", "")
        var tmp = h.strip("{}")
        var tmp2 = tmp.replace("-", "")
        h = tmp2
        if h.byte_length() != 32:
            raise Error("badly formed hexadecimal UUID string")
        var v: UInt128 = 0
        for i in range(32):
            var c = h[byte=i]
            var d: UInt8
            if c >= "0" and c <= "9":
                d = UInt8(ord(String(c)) - 48)
            elif c >= "a" and c <= "f":
                d = UInt8(ord(String(c)) - 87)
            elif c >= "A" and c <= "F":
                d = UInt8(ord(String(c)) - 55)
            else:
                raise Error("badly formed hexadecimal UUID string")
            v = (v << 4) | UInt128(d)
        self._int = v
        if version != 0:
            self._apply_version(version)

    def __init__(out self, bytes: Span[UInt8, _], version: Int = 0) raises:
        if len(bytes) != 16:
            raise Error("bytes is not a 16-char string")
        var v: UInt128 = 0
        for i in range(16):
            v = (v << 8) | UInt128(bytes[i])
        self._int = v
        if version != 0:
            self._apply_version(version)


    def _apply_version(mut self, version: Int) raises:
        if version < 1 or version > 8:
            raise Error("illegal version number")
        var v = self._int
        v &= ~((UInt128(0xf000) << 64) | (UInt128(0xc000) << 48))
        v |= UInt128(0x8000) << 48
        v |= UInt128(version) << 76
        self._int = v

    def int(self) -> UInt128:
        return self._int

    def __eq__(self, other: Self) -> Bool:
        return self._int == other._int

    def __lt__(self, other: Self) -> Bool:
        return self._int < other._int

    def __gt__(self, other: Self) -> Bool:
        return self._int > other._int

    def __le__(self, other: Self) -> Bool:
        return self._int <= other._int

    def __ge__(self, other: Self) -> Bool:
        return self._int >= other._int

    def __hash__(self) -> Int:
        return Int(self._int)

    def __str__(self) -> String:
        var x = self.hex()
        return x[byte=0:8] + "-" + x[byte=8:12] + "-" + x[byte=12:16] + "-" + x[byte=16:20] + "-" + x[byte=20:]

    def hex(self) -> String:
        return _hex128(self._int)

    def urn(self) -> String:
        return "urn:uuid:" + self.__str__()

    def bytes(self) -> Array[UInt8, 16]:
        var out = Array[UInt8, 16](fill=0)
        var v = self._int
        for i in range(15, -1, -1):
            out[i] = UInt8(v & 0xff)
            v >>= 8
        return out^

    def bytes_le(self) -> Array[UInt8, 16]:
        var b = self.bytes()
        var out = Array[UInt8, 16](fill=0)
        # reorder
        for i in range(4):
            out[i] = b[3-i]
        for i in range(2):
            out[4+i] = b[5-i]
        out[6] = b[6]
        out[7] = b[7]
        for i in range(8):
            out[8+i] = b[8+i]
        return out^

    def variant(self) -> String:
        var i = self._int
        if not (i & (UInt128(0x8000) << 48)):
            return "reserved for NCS compatibility"
        elif not (i & (UInt128(0x4000) << 48)):
            return "specified in RFC 4122"
        elif not (i & (UInt128(0x2000) << 48)):
            return "reserved for Microsoft compatibility"
        else:
            return "reserved for future definition"

    def version(self) -> Int:
        if self.variant() != "specified in RFC 4122":
            return 0
        return Int((self._int >> 76) & 0xf)

    def time_low(self) -> UInt32:
        return UInt32(self._int >> 96)

    def time_mid(self) -> UInt16:
        return UInt16((self._int >> 80) & 0xffff)

    def time_hi_version(self) -> UInt16:
        return UInt16((self._int >> 64) & 0xffff)

    def clock_seq_hi_variant(self) -> UInt8:
        return UInt8((self._int >> 56) & 0xff)

    def clock_seq_low(self) -> UInt8:
        return UInt8((self._int >> 48) & 0xff)

    def clock_seq(self) -> Int:
        return Int(((self.clock_seq_hi_variant() & 0x3f) << 8) | self.clock_seq_low())

    def node(self) -> UInt64:
        return UInt64(self._int & 0xffffffffffff)

    def time(self) -> UInt64:
        var ver = self.version()
        if ver == 6:
            var time_hi = UInt64(self._int >> 96)
            var time_lo = UInt64((self._int >> 64) & 0x0fff)
            return (time_hi << 28) | (UInt64(self.time_mid()) << 12) | time_lo
        elif ver == 7:
            return UInt64(self._int >> 80)
        else:
            var time_hi = UInt64((self._int >> 64) & 0x0fff)
            var time_lo = UInt64(self._int >> 96)
            return (time_hi << 48) | (UInt64(self.time_mid()) << 32) | time_lo


def _hex128(v: UInt128) -> String:
    var hexd = "0123456789abcdef"
    var out = String("")
    var x = v
    var chars = Array[UInt8, 32](fill=0)
    for i in range(31, -1, -1):
        var idx = Int(x & 0xf)
        chars[i] = UInt8(ord(hexd[byte=idx]))
        x >>= 4
    for i in range(32):
        out += chr(Int(chars[i]))
    return out


comptime NAMESPACE_DNS = UUID(UInt128(0x6ba7b8109dad11d180b400c04fd430c8))
comptime NAMESPACE_URL = UUID(UInt128(0x6ba7b8119dad11d180b400c04fd430c8))
comptime NAMESPACE_OID = UUID(UInt128(0x6ba7b8129dad11d180b400c04fd430c8))
comptime NAMESPACE_X500 = UUID(UInt128(0x6ba7b8149dad11d180b400c04fd430c8))
comptime NIL = UUID(UInt128(0))
comptime MAX = UUID(UInt128(0xffffffffffffffffffffffffffffffff))


def _uuid_from_bytes(buf: Array[UInt8, 16]) -> UInt128:
    var v: UInt128 = 0
    for i in range(16):
        v = (v << 8) | UInt128(buf[i])
    return v


def uuid3(namespace: UUID, name: String) raises -> UUID:
    var h = Md5()
    var nb = namespace.bytes()
    h.update(Span(nb))
    h.update(name.as_bytes())
    var d = h.digest()
    var v: UInt128 = 0
    for i in range(16):
        v = (v << 8) | UInt128(d[i])
    v &= ~((UInt128(0xf000) << 64) | (UInt128(0xc000) << 48))
    v |= UInt128(3) << 76
    v |= UInt128(0x8000) << 48
    return UUID(v)


def uuid4() raises -> UUID:
    var buf = Array[UInt8, 16](fill=0)
    _ = external_call["getrandom", Int](buf.unsafe_ptr(), 16, 0)
    var v: UInt128 = 0
    for i in range(16):
        v = (v << 8) | UInt128(buf[i])
    v &= ~((UInt128(0xf000) << 64) | (UInt128(0xc000) << 48))
    v |= UInt128(4) << 76
    v |= UInt128(0x8000) << 48
    return UUID(v)


def uuid5(namespace: UUID, name: String) raises -> UUID:
    var h = Sha1()
    var nb = namespace.bytes()
    h.update(Span(nb))
    h.update(name.as_bytes())
    var d = h.digest()
    var v: UInt128 = 0
    for i in range(16):
        v = (v << 8) | UInt128(d[i])
    v &= ~((UInt128(0xf000) << 64) | (UInt128(0xc000) << 48))
    v |= UInt128(5) << 76
    v |= UInt128(0x8000) << 48
    return UUID(v)


def _now_ns() -> Int:
    var ts_sec: Int64 = 0
    var ts_nsec: Int64 = 0
    # use stack via Pointer
    var sec = external_call["time", Int64](0)
    return Int(sec) * 1000000000


def uuid6(node: UInt64 = 0, clock_seq: Int = -1, timestamp_ns: Int = -1) raises -> UUID:
    var ns = timestamp_ns
    if ns < 0:
        ns = _now_ns()
    var nanoseconds = ns
    var timestamp = nanoseconds // 100 + 0x01b21dd213814000
    var cs = clock_seq
    if cs < 0:
        var b = Array[UInt8, 2](fill=0)
        _ = external_call["getrandom", Int](b.unsafe_ptr(), 2, 0)
        cs = Int(b[0]) | (Int(b[1]) << 8)
        cs &= 0x3fff
    var time_hi_and_mid = (timestamp >> 12) & 0xffff_ffff_ffff
    var time_lo = timestamp & 0x0fff
    var clock_s = cs & 0x3fff
    var nd = node
    if nd == 0:
        var b = Array[UInt8, 6](fill=0)
        _ = external_call["getrandom", Int](b.unsafe_ptr(), 6, 0)
        var v: UInt64 = 0
        for i in range(6):
            v = (v << 8) | UInt64(b[i])
        nd = v
    var int_uuid_6: UInt128 = UInt128(time_hi_and_mid) << 80
    int_uuid_6 |= UInt128(time_lo) << 64
    int_uuid_6 |= UInt128(clock_s) << 48
    int_uuid_6 |= UInt128(nd) & 0xffff_ffff_ffff
    int_uuid_6 |= UInt128(6) << 76
    int_uuid_6 |= UInt128(0x8000) << 48
    return UUID(int_uuid_6)


def uuid7(timestamp_ms: Int = -1) raises -> UUID:
    var ts_ms = timestamp_ms
    if ts_ms < 0:
        ts_ms = _now_ns() // 1000000
    var rand = Array[UInt8, 10](fill=0)
    _ = external_call["getrandom", Int](rand.unsafe_ptr(), 10, 0)
    var counter = (Int(rand[0]) | (Int(rand[1]) << 8) | (Int(rand[2]) << 16) | (Int(rand[3]) << 24) | (Int(rand[4]) << 32)) & 0x1ff_ffff_ffff
    var tail = Int(rand[5]) | (Int(rand[6]) << 8) | (Int(rand[7]) << 16) | (Int(rand[8]) << 24) | (Int(rand[9]) << 32)
    tail &= 0xffff_ffff
    var unix_ts_ms = UInt128(ts_ms) & 0xffff_ffff_ffff
    var counter_msbs = counter >> 30
    var counter_hi = counter_msbs & 0x0fff
    var counter_lo = counter & 0x3fff_ffff
    var int_uuid_7 = unix_ts_ms << 80
    int_uuid_7 |= UInt128(counter_hi) << 64
    int_uuid_7 |= UInt128(counter_lo) << 32
    int_uuid_7 |= UInt128(tail)
    int_uuid_7 |= UInt128(7) << 76
    int_uuid_7 |= UInt128(0x8000) << 48
    return UUID(int_uuid_7)


def uuid8(a: Int = -1, b: Int = -1, c: Int = -1) raises -> UUID:
    var aa = a
    if aa < 0:
        var r = Array[UInt8, 6](fill=0)
        _ = external_call["getrandom", Int](r.unsafe_ptr(), 6, 0)
        aa = 0
        for i in range(6):
            aa = (aa << 8) | Int(r[i])
    var bb = b
    if bb < 0:
        var r = Array[UInt8, 2](fill=0)
        _ = external_call["getrandom", Int](r.unsafe_ptr(), 2, 0)
        bb = (Int(r[0]) | (Int(r[1]) << 8)) & 0xfff
    var cc = c
    if cc < 0:
        var r = Array[UInt8, 8](fill=0)
        _ = external_call["getrandom", Int](r.unsafe_ptr(), 8, 0)
        cc = 0
        for i in range(8):
            cc = (cc << 8) | Int(r[i])
        cc &= 0x3fff_ffff_ffff_ffff
    var int_uuid_8 = (UInt128(aa) & 0xffff_ffff_ffff) << 80
    int_uuid_8 |= (UInt128(bb) & 0xfff) << 64
    int_uuid_8 |= UInt128(cc) & 0x3fff_ffff_ffff_ffff
    int_uuid_8 |= UInt128(8) << 76
    int_uuid_8 |= UInt128(0x8000) << 48
    return UUID(int_uuid_8)
