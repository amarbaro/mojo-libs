from base64 import b64decode, urlsafe_b64decode, b32decode, b32encode, b16decode
from std.collections import List

def b64_strict_raises(inp: String) -> Bool:
    var data = List[Byte]()
    for i in range(inp.byte_length()):
        data.append(UInt8(ord(inp[byte=i])))
    var sp = Span[UInt8, _](list=data)
    try:
        _ = b64decode(sp, List[Byte](), True)
    except e:
        return True
    return False

def main() raises:
    # leading '='
    if not b64_strict_raises("="): print("FAIL1"); return
    # excess padding at quad_pos 0
    if not b64_strict_raises("AAAA="): print("FAIL1b"); return
    # partial 2 chars -> Incorrect padding
    if not b64_strict_raises("YQ"): print("FAIL1c"); return
    # excess data after padding
    if not b64_strict_raises("YQ==A"): print("FAIL1d"); return
    # discontinuous
    if not b64_strict_raises("YQ=Q"): print("FAIL4"); return
    # non-alphabet
    if not b64_strict_raises("!!!!"): print("FAIL2"); return
    # excess padding
    if not b64_strict_raises("YQ==="): print("FAIL3"); return
    # discontinuous
    if not b64_strict_raises("YQ=Q"): print("FAIL4"); return
    # urlsafe '-' path: decode "-_": should not raise? Actually "-_" decodes to? test no raise with validate? Use invalid char
    # b32 odd length raises
    var bad32 = List[Byte]()
    for i in range(7):
        bad32.append(UInt8(ord('A')))
    var sp32 = Span[UInt8, _](list=bad32)
    var r32 = False
    try:
        _ = b32decode(sp32)
    except e:
        r32 = True
    if not r32: print("FAIL5"); return
    # b32 casefold: lowercase with casefold=True should succeed
    var low = List[Byte]()
    for c in "aaaa":
        low.append(UInt8(ord(c)))
    # pad to 8
    for i in range(4):
        low.append(UInt8(ord('=')))
    var splow = Span[UInt8, _](list=low)
    try:
        _ = b32decode(splow, True)
    except e:
        print("FAIL6"); return
    # b32 encode padding for 1 byte
    var one = List[Byte]()
    one.append(UInt8(ord('a')))
    var spone = Span[UInt8, _](list=one)
    var enc = b32encode(spone)
    var encs = String("")
    for i in range(len(enc)):
        encs += chr(Int(enc[i]))
    if encs != "ME======":
        print("FAIL7"); return
    # b16 invalid hex raises
    var bad16 = List[Byte]()
    for c in "ZZ":
        bad16.append(UInt8(ord(c)))
    var sp16 = Span[UInt8, _](list=bad16)
    var r16 = False
    try:
        _ = b16decode(sp16)
    except e:
        r16 = True
    if not r16: print("FAIL8"); return
    # urlsafe decode invalid char raises with validate
    var badu = List[Byte]()
    for c in "!!":
        badu.append(UInt8(ord(c)))
    var spu = Span[UInt8, _](list=badu)
    var ru = False
    try:
        _ = urlsafe_b64decode(spu, True)
    except e:
        ru = True
    if not ru: print("FAIL9"); return
    # urlsafe '-' translates: should succeed
    var oku = List[Byte]()
    for c in "-w==":
        oku.append(UInt8(ord(c)))
    var spou = Span[UInt8, _](list=oku)
    try:
        _ = urlsafe_b64decode(spou, True)
    except e:
        print("FAIL10"); return
    print("OK")
