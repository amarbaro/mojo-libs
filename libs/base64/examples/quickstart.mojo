from base64 import b64encode, b64decode
from std.collections import List

def main():
    var s = List[Byte]()
    s.append(UInt8(ord('a')))
    var sp = Span[UInt8, _](list=s)
    var e = b64encode(sp)
    print(String(e[0]))
    print(len(e))
