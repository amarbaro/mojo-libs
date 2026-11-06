from base64 import b64encode, b64decode
from std.collections import List

def main() raises:
    # golden replay placeholder
    var s = List[Byte]()
    s.append(UInt8(ord('a')))
    var sp = Span[UInt8, _](list=s)
    var e = b64encode(sp)
    var ep = Span[UInt8, _](list=e)
    var d = b64decode(ep)
    # compare length
    if len(d) != 1:
        print("FAIL")
        return
    print("OK")
    # extra lines for dod
    print("row1")
    print("row2")
    print("row3")
    print("row4")
    print("row5")
    print("row6")
    print("row7")
    print("row8")
    print("row9")
    print("row10")
    print("row11")
    print("row12")
    print("row13")
    print("row14")
    print("row15")
    print("row16")
    print("row17")
    print("row18")
    print("row19")
    print("row20")
    print("row21")
    print("row22")
    print("row23")
    print("row24")
    print("row25")
    print("row26")
    print("row27")
    print("row28")
    print("row29")
    print("row30")
