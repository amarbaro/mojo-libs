from std.collections import List

comptime _ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def _a2b(c: UInt8) -> Int:
    if c == UInt8(ord('=')):
        return -2
    if c >= 65 and c <= 90:
        return Int(c) - 65
    if c >= 97 and c <= 122:
        return Int(c) - 71
    if c >= 48 and c <= 57:
        return Int(c) + 4
    if c == UInt8(ord('+')):
        return 62
    if c == UInt8(ord('/')):
        return 63
    return -1

def _b64decode_core(data: List[Byte], strict: Bool) raises -> List[Byte]:
    var out = List[Byte]()
    var n = len(data)
    if strict and n > 0 and data[0] == UInt8(ord('=')):
        raise Error("Leading padding not allowed")
    var quad_pos = 0
    var leftchar: Int = 0
    var pads = 0
    var padding_started = False
    var done_padding = False
    var i = 0
    while i < n:
        var this_ch = data[i]
        if this_ch == UInt8(ord('=')):
            padding_started = True
            if strict and quad_pos == 0:
                raise Error("Excess padding not allowed")
            if quad_pos >= 2 and quad_pos + (pads + 1) >= 4:
                pads += 1
                if strict and i + 1 < n:
                    raise Error("Excess data after padding")
                done_padding = True
                break
            pads += 1
            i += 1
            continue
        var v = _a2b(this_ch)
        if v < 0:
            if strict:
                raise Error("Only base64 data is allowed")
            i += 1
            continue
        if strict and padding_started:
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
    if (not done_padding) and quad_pos != 0:
        if quad_pos == 1:
            raise Error("Invalid base64-encoded string: number of data characters (" + String(i) + ") cannot be 1 more than a multiple of 4")
        else:
            raise Error("Incorrect padding")
    return out^

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

def b64decode(s: Span[UInt8, _], altchars: List[Byte] = List[Byte](), validate: Bool = False) raises -> List[Byte]:
    var data = List[Byte]()
    for j in range(len(s)):
        data.append(s[j])
    if len(altchars) != 0:
        if len(altchars) != 2:
            raise Error("altchars must be length 2")
        for j in range(len(data)):
            if data[j] == altchars[0]:
                data[j] = UInt8(ord('+'))
            elif data[j] == altchars[1]:
                data[j] = UInt8(ord('/'))
    return _b64decode_core(data, validate)

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
    var data = List[Byte]()
    for j in range(len(s)):
        var c = s[j]
        if c == UInt8(ord('-')):
            c = UInt8(ord('+'))
        elif c == UInt8(ord('_')):
            c = UInt8(ord('/'))
        data.append(c)
    return _b64decode_core(data, validate)
def urlsafe_b64decode_into(s: Span[UInt8, _], mut out: List[Byte], validate: Bool = False) raises:
    var r = urlsafe_b64decode(s, validate)
    for j in range(len(r)):
        out.append(r[j])

# b32
comptime _B32ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
comptime _B32HEX = "0123456789ABCDEFGHIJKLMNOPQRSTUV"

def _b32_rev(alphabet: String, c: UInt8) -> Int:
    for k in range(32):
        if UInt8(ord(alphabet[byte=k])) == c:
            return k
    return -1

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
    var data = List[Byte]()
    for j in range(len(s)):
        data.append(s[j])
    if len(data) % 8 != 0:
        raise Error("Incorrect padding")
    if len(map01) != 0:
        if len(map01) != 1:
            raise Error("map01 must be length 1")
        for j in range(len(data)):
            if data[j] == UInt8(ord('0')):
                data[j] = UInt8(ord('O'))
            elif data[j] == UInt8(ord('1')):
                data[j] = map01[0]
    if casefold:
        for j in range(len(data)):
            var c = data[j]
            if c >= 97 and c <= 122:
                data[j] = c - 32
    var l = len(data)
    var stripped = List[Byte]()
    for j in range(len(data)):
        stripped.append(data[j])
    while len(stripped) > 0 and stripped[len(stripped)-1] == UInt8(ord('=')):
        _ = stripped.pop()
    var padchars = l - len(stripped)
    var out = List[Byte]()
    var idx = 0
    var nstripped = len(stripped)
    var acc_last: Int = 0
    while idx + 8 <= nstripped:
        var acc: Int = 0
        for k in range(8):
            var v = _b32_rev(alphabet, stripped[idx+k])
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
    if idx < nstripped:
        var acc: Int = 0
        var cnt = nstripped - idx
        for k in range(cnt):
            var v = _b32_rev(alphabet, stripped[idx+k])
            if v < 0:
                raise Error("Non-base32 digit found")
            acc = (acc << 5) + v
        out.append(UInt8((acc >> 32) & 255))
        out.append(UInt8((acc >> 24) & 255))
        out.append(UInt8((acc >> 16) & 255))
        out.append(UInt8((acc >> 8) & 255))
        out.append(UInt8(acc & 255))
        acc_last = acc
    if l % 8 != 0 or padchars not in (0,1,3,4,6):
        raise Error("Incorrect padding")
    if padchars != 0 and len(out) > 0:
        acc_last <<= 5 * padchars
        var b0 = (acc_last >> 32) & 255
        var b1 = (acc_last >> 24) & 255
        var b2 = (acc_last >> 16) & 255
        var b3 = (acc_last >> 8) & 255
        var b4 = acc_last & 255
        var lastbytes = List[Byte]()
        lastbytes.append(UInt8(b0)); lastbytes.append(UInt8(b1)); lastbytes.append(UInt8(b2)); lastbytes.append(UInt8(b3)); lastbytes.append(UInt8(b4))
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
    return _b32decode_with(_B32ALPHA, s, casefold, map01)
def b32decode_into(s: Span[UInt8, _], mut out: List[Byte], casefold: Bool = False, map01: List[Byte] = List[Byte]()) raises:
    var r = b32decode(s, casefold, map01)
    for j in range(len(r)):
        out.append(r[j])

def b32hexdecode(s: Span[UInt8, _], casefold: Bool = False) raises -> List[Byte]:
    return _b32decode_with(_B32HEX, s, casefold, List[Byte]())
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

def _hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return 0

def b16decode(s: Span[UInt8, _], casefold: Bool = False) raises -> List[Byte]:
    var data = List[Byte]()
    for j in range(len(s)):
        data.append(s[j])
    if casefold:
        for j in range(len(data)):
            var c = data[j]
            if c >= 97 and c <= 122:
                data[j] = c - 32
    for j in range(len(data)):
        var c = data[j]
        var ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 70)
        if not ok:
            raise Error("Non-base16 digit found")
    if len(data) % 2 != 0:
        raise Error("Odd-length string")
    var out = List[Byte]()
    var j = 0
    while j + 1 < len(data):
        var hi = _hexval(data[j])
        var lo = _hexval(data[j+1])
        out.append(UInt8((hi << 4) | lo))
        j += 2
    return out^

def b16decode_into(s: Span[UInt8, _], mut out: List[Byte], casefold: Bool = False) raises:
    var r = b16decode(s, casefold)
    for j in range(len(r)):
        out.append(r[j])
