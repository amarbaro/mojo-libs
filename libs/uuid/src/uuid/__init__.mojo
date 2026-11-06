"""RFC 9562 UUID values and generators with CPython constructor error texts."""
from std.collections import Array
from std.ffi import external_call
from hashlib import Md5, Sha1

@fieldwise_init
struct UUIDError(Copyable, Movable, Writable):
    var kind: String
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.kind, ": ", self.message)

struct UUID(Copyable, Movable, ImplicitlyCopyable):
    var _int: UInt128

    def __init__(out self, value: UInt128):
        self._int = value

    def __init__(out self) raises UUIDError:
        raise UUIDError("TypeError", "one of the hex, bytes, bytes_le, fields, or int arguments must be given")

    def __init__(out self, hex: String, version: Optional[Int] = None) raises UUIDError:
        # Canonical ASCII inputs need no normalization allocation.
        if hex.byte_length() == 32 or hex.byte_length() == 36:
            var bits: UInt128 = 0
            var digits = 0
            for c in hex.as_bytes():
                if c == 45:
                    continue
                var d = Int(c) - 48
                var folded = Int(c) | 32
                if folded >= 97 and folded <= 102:
                    d = folded - 87
                elif c < 48 or c > 57:
                    digits = -1
                    break
                bits = (bits << 4) | UInt128(d)
                digits += 1
            if digits == 32:
                self._int = bits
                if version:
                    self._apply_version(version.value())
                return
        var h = hex.replace("urn:", "")
        h = h.replace("uuid:", "")
        var tmp = h.strip("{}")
        var tmp2 = tmp.replace("-", "")
        h = tmp2
        if h.count_codepoints() != 32:
            raise UUIDError("ValueError", "badly formed hexadecimal UUID string")
        var original = h
        var trimmed = String(h.strip())
        h = trimmed^
        var negative = h.startswith("-")
        if h.startswith("+") or negative:
            var unsigned = String(h[byte=1:])
            h = unsigned^
        if h.startswith("0x") or h.startswith("0X"):
            var unprefixed = String(h[byte=2:])
            h = unprefixed^
        var v: UInt128 = 0
        var digit = False
        for i in range(h.byte_length()):
            var c = h[byte=i]
            if c == "_" and (digit or (i == 0 and original.strip().startswith("0x"))):
                digit = False
                continue
            var d: UInt8
            if c >= "0" and c <= "9":
                d = UInt8(ord(String(c)) - 48)
            elif c >= "a" and c <= "f":
                d = UInt8(ord(String(c)) - 87)
            elif c >= "A" and c <= "F":
                d = UInt8(ord(String(c)) - 55)
            else:
                raise UUIDError("ValueError", "invalid literal for int() with base 16: " + _repr(original))
            v = (v << 4) | UInt128(d)
            digit = True
        if not digit:
            raise UUIDError("ValueError", "invalid literal for int() with base 16: " + _repr(original))
        if negative and v != 0:
            raise UUIDError("ValueError", "int is out of range (need a 128-bit value)")
        self._int = v
        if version:
            self._apply_version(version.value())

    def __init__(out self, bytes: Span[UInt8, _], version: Optional[Int] = None, *, little_endian: Bool = False) raises UUIDError:
        if len(bytes) != 16:
            if little_endian:
                raise UUIDError("ValueError", "bytes_le is not a 16-char string")
            raise UUIDError("ValueError", "bytes is not a 16-char string")
        var v: UInt128 = 0
        for i in range(16):
            var j = i
            if little_endian and i < 8:
                j = 3-i if i < 4 else (9-i if i < 6 else 13-i)
            v = (v << 8) | UInt128(bytes[j])
        self._int = v
        if version:
            self._apply_version(version.value())

    @staticmethod
    def from_fields(fields: Span[Int, _], version: Optional[Int] = None) raises UUIDError -> Self:
        if len(fields) != 6:
            raise UUIDError("ValueError", "fields is not a 6-tuple")
        var widths: Array[Int, 6] = [32, 16, 16, 8, 8, 48]
        var v: UInt128 = 0
        for i in range(6):
            if fields[i] < 0 or fields[i] >= (1 << widths[i]):
                var article = "an " if widths[i] == 8 else "a "
                raise UUIDError("ValueError", "field " + String(i+1) + " out of range (need " + article + String(widths[i]) + "-bit value)")
            v = (v << UInt128(widths[i])) | UInt128(fields[i])
        var result = Self(v)
        if version:
            result._apply_version(version.value())
        return result

    @staticmethod
    def from_int(value: String, version: Optional[Int] = None) raises UUIDError -> Self:
        var v: UInt128 = 0
        if value.byte_length() == 0:
            raise UUIDError("ValueError", "invalid literal for int() with base 10: " + _repr(value))
        for c in value.codepoints():
            var d = Int(c) - 48
            if d < 0 or d > 9:
                raise UUIDError("ValueError", "int is out of range (need a 128-bit value)")
            if v > (UInt128(0xffffffffffffffffffffffffffffffff) - UInt128(d)) // 10:
                raise UUIDError("ValueError", "int is out of range (need a 128-bit value)")
            v = v * 10 + UInt128(d)
        var result = Self(v)
        if version:
            result._apply_version(version.value())
        return result

    def _apply_version(mut self, version: Int) raises UUIDError:
        if version < 1 or version > 8:
            raise UUIDError("ValueError", "illegal version number")
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
        return Int(self._int % ((UInt128(1) << 61) - 1))

    def __str__(self) -> String:
        var chars = Array[UInt8, 36](fill=45)
        var v = self._int
        var hexd = "0123456789abcdef"
        for i in range(35, -1, -1):
            if i == 8 or i == 13 or i == 18 or i == 23:
                continue
            chars[i] = hexd.as_bytes()[Int(v & 0xf)]
            v >>= 4
        return String(unsafe_from_utf8=Span(chars))

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
        out[6] = b[7]
        out[7] = b[6]
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
        return (Int(self.clock_seq_hi_variant() & 0x3f) << 8) | Int(self.clock_seq_low())

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


def _repr(value: String) -> String:
    var quote = "\"" if "'" in value and not "\"" in value else "'"
    return quote + value.replace("\\", "\\\\").replace(quote, "\\" + quote).replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + quote


def _hex128(v: UInt128) -> String:
    var hexd = "0123456789abcdef"
    var x = v
    var chars = Array[UInt8, 32](fill=0)
    for i in range(31, -1, -1):
        var idx = Int(x & 0xf)
        chars[i] = UInt8(ord(hexd[byte=idx]))
        x >>= 4
    return String(unsafe_from_utf8=Span(chars))


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
    _random_fill(buf)
    return _uuid4_from(buf)


def _uuid4_from(buf: Array[UInt8, 16]) -> UUID:
    var v = _uuid_from_bytes(buf)
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
    var ts = Array[Int64, 2](fill=0)
    _ = external_call["clock_gettime", Int32](Int32(0), ts.unsafe_ptr())
    return Int(ts[0]) * 1000000000 + Int(ts[1])


def _random_fill[n: Int](mut buf: Array[UInt8, n]) raises:
    var offset = 0
    while offset < n:
        var got = external_call["getrandom", Int](buf.unsafe_ptr().unsafe_offset(offset), n-offset, 0)
        if got <= 0:
            raise Error("getrandom failed")
        offset += got


def uuid6(node: Optional[Int] = None, clock_seq: Int = -1, timestamp_ns: Int = -1) raises -> UUID:
    var ns = timestamp_ns
    if ns < 0:
        ns = _now_ns()
    var nanoseconds = ns
    var timestamp = nanoseconds // 100 + 0x01b21dd213814000
    var cs = clock_seq
    if cs < 0:
        var b = Array[UInt8, 2](fill=0)
        _random_fill(b)
        cs = Int(b[0]) | (Int(b[1]) << 8)
        cs &= 0x3fff
    var time_hi_and_mid = (timestamp >> 12) & 0xffff_ffff_ffff
    var time_lo = timestamp & 0x0fff
    var clock_s = cs & 0x3fff
    var nd: UInt64 = 0
    if node:
        nd = UInt64(node.value())
    else:
        var b = Array[UInt8, 6](fill=0)
        _random_fill(b)
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


def _uuid7_from(timestamp_ms: Int, counter: UInt64, tail: UInt32) -> UUID:
    var v = (UInt128(timestamp_ms) & 0xffffffffffff) << 80
    v |= UInt128((counter >> 30) & 0xfff) << 64
    v |= UInt128(counter & 0x3fffffff) << 32
    v |= UInt128(tail)
    v |= UInt128(7) << 76
    v |= UInt128(0x8000) << 48
    return UUID(v)


def uuid7(timestamp_ms: Int = -1) raises -> UUID:
    var ts_ms = timestamp_ms
    if ts_ms < 0:
        ts_ms = _now_ns() // 1000000
    var rand = Array[UInt8, 10](fill=0)
    _random_fill(rand)
    var counter: UInt64 = 0
    for i in range(6):
        counter = (counter << 8) | UInt64(rand[i])
    var tail: UInt32 = 0
    for i in range(6, 10):
        tail = (tail << 8) | UInt32(rand[i])
    return _uuid7_from(ts_ms, counter & 0x1ffffffffff, tail)


def uuid8(a: Optional[Int] = None, b: Optional[Int] = None, c: Optional[Int] = None) raises -> UUID:
    var aa = 0
    if a:
        aa = a.value()
    else:
        var r = Array[UInt8, 6](fill=0)
        _random_fill(r)
        aa = 0
        for i in range(6):
            aa = (aa << 8) | Int(r[i])
    var bb = 0
    if b:
        bb = b.value()
    else:
        var r = Array[UInt8, 2](fill=0)
        _random_fill(r)
        bb = (Int(r[0]) | (Int(r[1]) << 8)) & 0xfff
    var cc = 0
    if c:
        cc = c.value()
    else:
        var r = Array[UInt8, 8](fill=0)
        _random_fill(r)
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


struct UUID6Generator:
    """Caller-owned monotonic timestamp, CPython uuid.py L807-813."""
    var last_timestamp: Int

    def __init__(out self):
        self.last_timestamp = -1

    def next(mut self, timestamp_ns: Int, node: UInt64, clock_seq: Int) raises -> UUID:
        var timestamp = timestamp_ns // 100 + 0x01b21dd213814000
        if timestamp <= self.last_timestamp:
            timestamp = self.last_timestamp + 1
        self.last_timestamp = timestamp
        return uuid6(Int(node), clock_seq, (timestamp - 0x01b21dd213814000) * 100)


struct UUID7Generator:
    """Caller-owned CPython uuid7 state, uuid.py L844-905; no hidden globals."""
    var last_timestamp: Int
    var counter: UInt64

    def __init__(out self):
        self.last_timestamp = -1
        self.counter = 0

    def from_random(mut self, timestamp_ms: Int, random: Array[UInt8, 10]) -> UUID:
        var timestamp = timestamp_ms
        var next_counter = self.counter
        var tail: UInt32 = 0
        for i in range(6, 10):
            tail = (tail << 8) | UInt32(random[i])
        var fresh = timestamp > self.last_timestamp
        if not fresh:
            if timestamp < self.last_timestamp:
                timestamp = self.last_timestamp + 1
            next_counter += 1
            if next_counter > 0x3ffffffffff:
                timestamp += 1
                fresh = True
        if fresh:
            next_counter = 0
            for i in range(6):
                next_counter = (next_counter << 8) | UInt64(random[i])
            next_counter &= 0x1ffffffffff
        var result = _uuid7_from(timestamp, next_counter, tail)
        self.last_timestamp = timestamp
        self.counter = next_counter
        return result

    def next(mut self, timestamp_ms: Int = -1) raises -> UUID:
        var random = Array[UInt8, 10](fill=0)
        _random_fill(random)
        return self.from_random(_now_ns() // 1000000 if timestamp_ms < 0 else timestamp_ms, random)
