from csv import *

def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^

def main() raises:
    # reader
    var inp = _bytes("a,\"b,c\",d\ne,f,g\n")
    var r = Reader(Dialect.excel()^)
    var rows = r.read_all(Span[UInt8, _](unsafe_ptr=inp.unsafe_ptr(), length=len(inp)))
    if len(rows) != 2:
        raise Error("bad row count")
    if len(rows[0]) != 3 or len(rows[1]) != 3:
        raise Error("bad field count")
    # writer
    var rows2 = List[List[CsvField]]()
    var r1 = List[CsvField](); r1.append(CsvField(_bytes("a"), False)); r1.append(CsvField(_bytes("b"), False))
    var r2 = List[CsvField](); r2.append(CsvField(_bytes("c"), False)); r2.append(CsvField(_bytes("d"), False))
    rows2.append(r1^); rows2.append(r2^)
    var out = write_all(rows2, Dialect.excel()^)
    var exp = _bytes("a,b\r\nc,d\r\n")
    if len(out) != len(exp):
        raise Error("bad writer length")
    var i = 0
    while i < len(exp):
        if out[i] != exp[i]:
            raise Error("bad writer bytes")
        i += 1
    print("PASS cases")