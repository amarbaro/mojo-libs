from csv import *
def main() raises:
    var input = List[UInt8]()
    for b in "a,b\nc,d\n".as_bytes():
        input.append(b)
    var r = Reader(Dialect.excel()^)
    var rows = r.read_all(Span[UInt8, _](unsafe_ptr=input.unsafe_ptr(), length=len(input)))
    if len(rows) != 2:
        print("FAIL rows")
    else:
        print("PASS cases")