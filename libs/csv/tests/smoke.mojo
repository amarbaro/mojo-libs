from csv import *

def main() raises:
    var input = List[UInt8]()
    for b in ",\n".as_bytes():
        input.append(b)
    var d = Dialect.excel()
    var r = Reader(d^)
    var rows = r.read_all(Span[UInt8, _](unsafe_ptr=input.unsafe_ptr(), length=len(input)))
    print("rows", len(rows))
    for row in rows:
        print("fields", len(row))
        for f in row:
            print(f.data)