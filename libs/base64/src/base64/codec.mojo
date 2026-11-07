from std.collections import List, Array

comptime _ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

@always_inline
def _make_b64_table() -> Array[Int8, 256]:
    var t = Array[Int8, 256](fill=-1)
    for i in range(26):
        t[65 + i] = Int8(i)
        t[97 + i] = Int8(26 + i)
    for i in range(10):
        t[48 + i] = Int8(52 + i)
    t[Int(ord('+'))] = 62
    t[Int(ord('/'))] = 63
    t[Int(ord('='))] = -2
    return t^

def _b64decode_into_kernel(s: Span[UInt8, _], mut out: List[Byte], altchars: Span[UInt8, _], strict: Bool) raises:
    var n = len(s)
    if strict and n > 0 and s[0] == UInt8(ord('=')):
        raise Error("Leading padding not allowed")
    var has_alt = len(altchars) != 0
    var alt0: UInt8 = 0
    var alt1: UInt8 = 0
    if has_alt:
        if len(altchars) != 2:
            raise Error(_bytes_repr(List[Byte](altchars)))
        alt0 = altchars[0]
        alt1 = altchars[1]

    var t = _make_b64_table()
    var quad_pos = 0
    var leftchar: Int = 0
    var pads = 0
    var i = 0
    var orig_len = len(out)

    # Fast 4-byte chunk loop for clean ASCII base64
    if not has_alt:
        while i + 4 <= n:
            var c0 = Int(s[i])
            var c1 = Int(s[i+1])
            var c2 = Int(s[i+2])
            var c3 = Int(s[i+3])
            var v0 = Int(t[c0])
            var v1 = Int(t[c1])
            var v2 = Int(t[c2])
            var v3 = Int(t[c3])
            if (v0 | v1 | v2 | v3) >= 0:
                var trip = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3
                out.append(UInt8(trip >> 16))
                out.append(UInt8((trip >> 8) & 255))
                out.append(UInt8(trip & 255))
                i += 4
            else:
                break

    while i < n:
        var this_ch = s[i]
        if has_alt:
            if this_ch == alt1:
                this_ch = UInt8(ord('/'))
            elif this_ch == alt0:
                this_ch = UInt8(ord('+'))
        if this_ch == UInt8(ord('=')):
            pads += 1
            if quad_pos >= 2 and quad_pos + pads <= 4:
                i += 1
                continue
            if strict:
                if quad_pos == 1:
                    break
                raise Error("Excess padding not allowed")
            i += 1
            continue
        var v = Int(t[Int(this_ch)])
        if v < 0:
            if strict:
                raise Error("Only base64 data is allowed")
            i += 1
            continue
        if strict and pads != 0:
            if quad_pos + pads == 4:
                raise Error("Excess data after padding")
            raise Error("Discontinuous padding not allowed")
        pads = 0
        if quad_pos == 0:
            quad_pos = 1
            leftchar = v
        elif quad_pos == 1:
            quad_pos = 2
            out.append(UInt8((leftchar << 2) | (v >> 4)))
            leftchar = v & 15
        elif quad_pos == 2:
            quad_pos = 3
            out.append(UInt8((leftchar << 4) | (v >> 2)))
            leftchar = v & 3
        else:
            quad_pos = 0
            out.append(UInt8((leftchar << 6) | v))
            leftchar = 0
        i += 1

    if quad_pos == 1:
        raise Error("Invalid base64-encoded string: number of data characters (" + String(((len(out) - orig_len) // 3) * 4 + 1) + ") cannot be 1 more than a multiple of 4")
    if quad_pos != 0 and quad_pos + pads < 4:
        raise Error("Incorrect padding")

def b64encode(s: Span[UInt8, _]) -> List[Byte]:
    var out = List[Byte]()
    b64encode_into(s, out)
    return out^

def b64encode_into(s: Span[UInt8, _], mut out: List[Byte]):
    var n = len(s)
    var i = 0
    while i + 3 <= n:
        var b0 = Int(s[i]); var b1 = Int(s[i+1]); var b2 = Int(s[i+2])
        out.append(UInt8(ord(_ALPHA[byte=(b0 >> 2) & 63])))
        out.append(UInt8(ord(_ALPHA[byte=((b0 & 3) << 4) | (b1 >> 4)])))
        out.append(UInt8(ord(_ALPHA[byte=((b1 & 15) << 2) | (b2 >> 6)])))
        out.append(UInt8(ord(_ALPHA[byte=b2 & 63])))
        i += 3
    var rem = n - i
    if rem == 1:
        var b0 = Int(s[i])
        out.append(UInt8(ord(_ALPHA[byte=(b0 >> 2) & 63])))
        out.append(UInt8(ord(_ALPHA[byte=((b0 & 3) << 4)])))
        out.append(UInt8(ord('=')))
        out.append(UInt8(ord('=')))
    elif rem == 2:
        var b0 = Int(s[i]); var b1 = Int(s[i+1])
        out.append(UInt8(ord(_ALPHA[byte=(b0 >> 2) & 63])))
        out.append(UInt8(ord(_ALPHA[byte=((b0 & 3) << 4) | (b1 >> 4)])))
        out.append(UInt8(ord(_ALPHA[byte=((b1 & 15) << 2)])))
        out.append(UInt8(ord('=')))

def _bytes_repr(data: List[Byte]) -> String:
    var single = False
    var double = False
    for i in range(len(data)):
        single = single or data[i] == 39
        double = double or data[i] == 34
    var quote = 34 if single and not double else 39
    var result = String("b") + chr(quote)
    comptime hexchars = "0123456789abcdef"
    for i in range(len(data)):
        var c = Int(data[i])
        if c == quote or c == 92:
            result += String("\\") + chr(c)
        elif c == 9: result += "\\t"
        elif c == 10: result += "\\n"
        elif c == 13: result += "\\r"
        elif c < 32 or c >= 127:
            result += String("\\x") + String(hexchars[byte=c >> 4]) + String(hexchars[byte=c & 15])
        else:
            result += chr(c)
    return result + chr(quote)

def b64decode(s: Span[UInt8, _], altchars: List[Byte] = List[Byte](), validate: Bool = False) raises -> List[Byte]:
    var out = List[Byte]()
    out.reserve((len(s) * 3) // 4 + 3)
    _b64decode_into_kernel(s, out, Span(altchars), validate)
    return out^

def b64decode_into(s: Span[UInt8, _], mut out: List[Byte], altchars: List[Byte] = List[Byte](), validate: Bool = False) raises:
    var r = b64decode(s, altchars, validate)
    for j in range(len(r)):
        out.append(r[j])

# standard
def standard_b64encode(s: Span[UInt8, _]) -> List[Byte]:
    return b64encode(s)

def standard_b64encode_into(s: Span[UInt8, _], mut out: List[Byte]):
    b64encode_into(s, out)

def standard_b64decode(s: Span[UInt8, _], validate: Bool = False) raises -> List[Byte]:
    return b64decode(s, List[Byte](), validate)

def standard_b64decode_into(s: Span[UInt8, _], mut out: List[Byte], validate: Bool = False) raises:
    b64decode_into(s, out, List[Byte](), validate)

# urlsafe
def urlsafe_b64encode(s: Span[UInt8, _]) -> List[Byte]:
    var r = b64encode(s)
    for j in range(len(r)):
        if r[j] == UInt8(ord('+')):
            r[j] = UInt8(ord('-'))
        elif r[j] == UInt8(ord('/')):
            r[j] = UInt8(ord('_'))
    return r^

def urlsafe_b64encode_into(s: Span[UInt8, _], mut out: List[Byte]):
    var r = urlsafe_b64encode(s)
    for j in range(len(r)):
        out.append(r[j])

def urlsafe_b64decode(s: Span[UInt8, _], validate: Bool = False) raises -> List[Byte]:
    var out = List[Byte]()
    out.reserve((len(s) * 3) // 4 + 3)
    var alt = Array[UInt8, 2](fill=0)
    alt[0] = UInt8(ord('-'))
    alt[1] = UInt8(ord('_'))
    _b64decode_into_kernel(s, out, Span(alt), validate)
    return out^

def urlsafe_b64decode_into(s: Span[UInt8, _], mut out: List[Byte], validate: Bool = False) raises:
    var r = urlsafe_b64decode(s, validate)
    for j in range(len(r)):
        out.append(r[j])

# b32
comptime _B32ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
comptime _B32HEX = "0123456789ABCDEFGHIJKLMNOPQRSTUV"

@always_inline
def _make_b32_table(alphabet: String) -> Array[Int8, 256]:
    var t = Array[Int8, 256](fill=-1)
    for k in range(32):
        t[Int(ord(alphabet[byte=k]))] = Int8(k)
    return t^

def _b32encode_with(alphabet: String, s: Span[UInt8, _]) -> List[Byte]:
    var out = List[Byte]()
    var n = len(s)
    var leftover = n % 5
    var padded = n
    if leftover != 0:
        padded = n + (5 - leftover)
    var buf = List[Byte]()
    for j in range(n):
        buf.append(s[j])
    for j in range(n, padded):
        buf.append(UInt8(0))
    var i = 0
    while i < padded:
        var c = (Int(buf[i]) << 32) | (Int(buf[i+1]) << 24) | (Int(buf[i+2]) << 16) | (Int(buf[i+3]) << 8) | Int(buf[i+4])
        out.append(UInt8(ord(alphabet[byte=(c >> 35) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 30) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 25) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 20) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 15) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 10) & 31])))
        out.append(UInt8(ord(alphabet[byte=(c >> 5) & 31])))
        out.append(UInt8(ord(alphabet[byte=c & 31])))
        i += 5
    if leftover == 1:
        var L = len(out)
        for j in range(L-6, L):
            out[j] = UInt8(ord('='))
    elif leftover == 2:
        var L = len(out)
        for j in range(L-4, L):
            out[j] = UInt8(ord('='))
    elif leftover == 3:
        var L = len(out)
        for j in range(L-3, L):
            out[j] = UInt8(ord('='))
    elif leftover == 4:
        var L = len(out)
        out[L-1] = UInt8(ord('='))
    return out^

def b32encode(s: Span[UInt8, _]) -> List[Byte]:
    return _b32encode_with(_B32ALPHA, s)

def b32encode_into(s: Span[UInt8, _], mut out: List[Byte]):
    var r = b32encode(s)
    for j in range(len(r)):
        out.append(r[j])

def _b32decode_with(alphabet: String, s: Span[UInt8, _], casefold: Bool, map01: Span[UInt8, _]) raises -> List[Byte]:
    var l = len(s)
    if l % 8 != 0:
        raise Error("Incorrect padding")
    var has_map01 = len(map01) != 0
    if has_map01:
        if len(map01) != 1:
            raise Error(_bytes_repr(List[Byte](map01)))

    var end = l
    while end > 0 and s[end - 1] == UInt8(ord('=')):
        end -= 1
    var padchars = l - end

    var t = _make_b32_table(alphabet)
    var out = List[Byte]()
    out.reserve((l * 5) // 8 + 5)
    var idx = 0
    var acc_last: Int = 0
    while idx + 8 <= end:
        var acc: Int = 0
        for k in range(8):
            var c = s[idx + k]
            if has_map01:
                if c == UInt8(ord('0')):
                    c = UInt8(ord('O'))
                elif c == UInt8(ord('1')):
                    c = map01[0]
            if casefold and c >= 97 and c <= 122:
                c -= 32
            var v = Int(t[Int(c)])
            if v < 0:
                raise Error("Non-base32 digit found")
            acc = (acc << 5) + v
        out.append(UInt8((acc >> 32) & 255))
        out.append(UInt8((acc >> 24) & 255))
        out.append(UInt8((acc >> 16) & 255))
        out.append(UInt8((acc >> 8) & 255))
        out.append(UInt8(acc & 255))
        acc_last = acc
        idx += 8

    if idx < end:
        var acc: Int = 0
        var cnt = end - idx
        for k in range(cnt):
            var c = s[idx + k]
            if has_map01:
                if c == UInt8(ord('0')):
                    c = UInt8(ord('O'))
                elif c == UInt8(ord('1')):
                    c = map01[0]
            if casefold and c >= 97 and c <= 122:
                c -= 32
            var v = Int(t[Int(c)])
            if v < 0:
                raise Error("Non-base32 digit found")
            acc = (acc << 5) + v
        out.append(UInt8((acc >> 32) & 255))
        out.append(UInt8((acc >> 24) & 255))
        out.append(UInt8((acc >> 16) & 255))
        out.append(UInt8((acc >> 8) & 255))
        out.append(UInt8(acc & 255))
        acc_last = acc

    if padchars not in (0, 1, 3, 4, 6):
        raise Error("Incorrect padding")

    if padchars != 0 and len(out) > 0:
        acc_last <<= 5 * padchars
        var b0 = UInt8((acc_last >> 32) & 255)
        var b1 = UInt8((acc_last >> 24) & 255)
        var b2 = UInt8((acc_last >> 16) & 255)
        var b3 = UInt8((acc_last >> 8) & 255)
        var b4 = UInt8(acc_last & 255)
        var lastbytes = Array[UInt8, 5](fill=0)
        lastbytes[0] = b0
        lastbytes[1] = b1
        lastbytes[2] = b2
        lastbytes[3] = b3
        lastbytes[4] = b4
        var leftover = (43 - 5 * padchars) // 8
        var newlen = len(out) - (5 - leftover)
        while len(out) > newlen:
            _ = out.pop()
        var base2 = len(out) - leftover
        if base2 < 0:
            base2 = 0
        for k in range(leftover):
            if base2 + k < len(out):
                out[base2 + k] = lastbytes[k]
            else:
                out.append(lastbytes[k])
    return out^

def b32decode(s: Span[UInt8, _], casefold: Bool = False, map01: List[Byte] = List[Byte]()) raises -> List[Byte]:
    return _b32decode_with(_B32ALPHA, s, casefold, Span(map01))

def b32decode_into(s: Span[UInt8, _], mut out: List[Byte], casefold: Bool = False, map01: List[Byte] = List[Byte]()) raises:
    var r = b32decode(s, casefold, map01)
    for j in range(len(r)):
        out.append(r[j])

def b32hexdecode(s: Span[UInt8, _], casefold: Bool = False) raises -> List[Byte]:
    var empty = List[Byte]()
    return _b32decode_with(_B32HEX, s, casefold, Span(empty))

def b32hexdecode_into(s: Span[UInt8, _], mut out: List[Byte], casefold: Bool = False) raises:
    var r = b32hexdecode(s, casefold)
    for j in range(len(r)):
        out.append(r[j])

def b32hexencode(s: Span[UInt8, _]) -> List[Byte]:
    return _b32encode_with(_B32HEX, s)

def b32hexencode_into(s: Span[UInt8, _], mut out: List[Byte]):
    var r = b32hexencode(s)
    for j in range(len(r)):
        out.append(r[j])

# b16
comptime _HEX = "0123456789ABCDEF"

def b16encode(s: Span[UInt8, _]) -> List[Byte]:
    var out = List[Byte]()
    b16encode_into(s, out)
    return out^

def b16encode_into(s: Span[UInt8, _], mut out: List[Byte]):
    for j in range(len(s)):
        var b = Int(s[j])
        out.append(UInt8(ord(_HEX[byte=(b >> 4) & 15])))
        out.append(UInt8(ord(_HEX[byte=b & 15])))

@always_inline
def _hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return 0

def b16decode(s: Span[UInt8, _], casefold: Bool = False) raises -> List[Byte]:
    for j in range(len(s)):
        var c = s[j]
        if casefold and c >= 97 and c <= 122:
            c -= 32
        var ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 70)
        if not ok:
            raise Error("Non-base16 digit found")
    if len(s) % 2 != 0:
        raise Error("Odd-length string")
    var out = List[Byte]()
    out.reserve(len(s) // 2)
    var j = 0
    while j + 1 < len(s):
        var c_hi = s[j]
        if casefold and c_hi >= 97 and c_hi <= 122:
            c_hi -= 32
        var c_lo = s[j+1]
        if casefold and c_lo >= 97 and c_lo <= 122:
            c_lo -= 32
        var hi = _hexval(c_hi)
        var lo = _hexval(c_lo)
        out.append(UInt8((hi << 4) | lo))
        j += 2
    return out^

def b16decode_into(s: Span[UInt8, _], mut out: List[Byte], casefold: Bool = False) raises:
    var r = b16decode(s, casefold)
    for j in range(len(r)):
        out.append(r[j])
