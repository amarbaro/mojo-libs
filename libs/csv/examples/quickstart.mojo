from csv import Reader, Dialect, write_all


def main() raises:
    var input = List[UInt8]()
    for c in "alpha,\"beta,gamma\"\nnext,row\n".as_bytes():
        input.append(c)
    var reader = Reader(Dialect.excel())
    var rows = reader.read_all(Span(input))
    if len(rows) != 2 or len(rows[0]) != 2:
        raise Error("quickstart parse failed")
    var output = write_all(rows, Dialect.excel())
    if len(output) != len(input) + 2:
        raise Error("quickstart CRLF output failed")
    print("rows", len(rows), "fields", len(rows[0]), "written bytes", len(output))
