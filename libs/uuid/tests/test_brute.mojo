"""Independent bit-by-bit oracle, 10,000 deterministic UInt128 inputs."""
from uuid import UUID
from support import check

def slow_hex(v: UInt128) -> String:
    var result = String()
    for nibble in range(31, -1, -1):
        var digit = 0
        for bit in range(4):
            if (v >> UInt128(nibble*4 + bit)) & 1:
                digit += 1 << bit
        result += chr(48 + digit if digit < 10 else 87 + digit)
    return result

def slow_parse(text: String) -> UInt128:
    var v: UInt128 = 0
    for cp in text.codepoints():
        var c = Int(cp)
        if c == 45:
            continue
        v = v * 16 + UInt128(c-48 if c <= 57 else c-87)
    return v

def brute_tests() raises:
    var state: UInt128 = 0x123456789abcdef0fedcba9876543210
    for _ in range(10000):
        state = state * UInt128(6364136223846793005) + 1442695040888963407
        var u = UUID(state)
        var expected = slow_hex(state)
        check(u.hex() == expected, "brute hex")
        var rendered = u.__str__()
        check(rendered.byte_length() == 36, "render length")
        check(rendered[byte=8] == "-" and rendered[byte=13] == "-" and rendered[byte=18] == "-" and rendered[byte=23] == "-", "hyphen positions")
        check(slow_parse(rendered) == state, "independent parse")
        check(UUID(rendered).int() == state, "parse roundtrip")
        var bytes = u.bytes()
        check(UUID(Span(bytes)).int() == state, "bytes roundtrip")
        var little = u.bytes_le()
        check(UUID(Span(little), little_endian=True).int() == state, "bytes_le roundtrip")
        check(little[6] == bytes[7] and little[7] == bytes[6], "bytes_le third field")
        check(u.clock_seq() == Int((state >> 48) & 0x3fff), "clock_seq")
        check(u.node() == UInt64(state & 0xffffffffffff), "node")
    print("PASS brute: 10000 independent formatter/parser and byte round trips")

def main() raises:
    brute_tests()
