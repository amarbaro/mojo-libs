"""Replay CPython byte/null/error vectors. No Python runs inside these tests."""
from csv import *
from std.os import getenv


def unhex(text: StringSlice) -> List[UInt8]:
    var data = List[UInt8]()
    var i = 0
    while i < text.byte_length():
        var a = Int(text.as_bytes()[i])
        var b = Int(text.as_bytes()[i + 1])
        data.append(UInt8((a - 48 if a <= 57 else a - 87) * 16 + (b - 48 if b <= 57 else b - 87)))
        i += 2
    return data^


def hex_bytes(data: List[UInt8]) -> String:
    var result = String()
    var digits = "0123456789abcdef"
    for c in data:
        result += String(digits[byte=Int(c) >> 4])
        result += String(digits[byte=Int(c) & 15])
    return result^


def encode_rows(rows: List[List[CsvField]]) -> String:
    var result = String()
    for i in range(len(rows)):
        if i > 0:
            result += "/"
        if len(rows[i]) == 0:
            result += "~"
        for j in range(len(rows[i])):
            if j > 0:
                result += ","
            if rows[i][j].is_null:
                result += "n"
            else:
                result += "s" + hex_bytes(rows[i][j].data)
    return result^


def decode_rows(text: StringSlice) raises -> List[List[CsvField]]:
    var rows = List[List[CsvField]]()
    if text.byte_length() == 0:
        return rows^
    for line in text.split("/"):
        var row = List[CsvField]()
        if String(line) != "~":
            for field in line.split(","):
                row.append(CsvField(unhex(field[byte=1:]), String(field) == "n"))
        rows.append(row^)
    return rows^


def parse_lines(text: StringSlice, var dialect: Dialect) raises -> List[List[CsvField]]:
    # Inject iterator EOL separately to reach branches unavailable to StringIO lines.
    dialect.validate()
    var reader = Reader(dialect^)
    var rows = List[List[CsvField]]()
    var row = List[CsvField]()
    for line in text.split(","):
        var data = unhex(line)
        for c in data:
            _ = reader._process(Int(c), row)
        if reader._process(-1, row):
            rows.append(row^)
            row = List[CsvField]()
    if len(reader.scratch) != 0 or reader.state == IN_QUOTED_FIELD:
        if reader.dialect.strict:
            raise Error("unexpected end of data")
        reader._save_field(row)
        rows.append(row^)
    return rows^


def replay() raises:
    var path = getenv("GOLDENS", "tests/golden/vectors.txt")
    var file = open(path, "r")
    var content = file.read()
    var count = 0
    for line in content.split("\n"):
        if line.byte_length() == 0:
            continue
        var parts = line.split("|")
        if len(parts) != 12:
            raise Error("invalid golden row")
        var escape = Int(parts[4])
        var d = Dialect(delimiter=UInt8(Int(parts[2])), quotechar=UInt8(Int(parts[3])),
                        escapechar=UInt8(0 if escape < 0 else escape), has_escape=escape >= 0,
                        doublequote=Int(parts[5]) != 0, skipinitialspace=Int(parts[6]) != 0,
                        strict=Int(parts[7]) != 0, quoting=Int(parts[8]))
        d.lineterminator = unhex(parts[9])
        var actual = String()
        var failed = False
        try:
            if String(parts[1]) == "R":
                var input = unhex(parts[10])
                var reader = Reader(d^)
                var rows = reader.read_all(Span(input))
                actual = encode_rows(rows)
                # Reusing the reader must reset state and retained scratch.
                var again = reader.read_all(Span(input))
                if encode_rows(again) != actual:
                    raise Error("reader reuse differs")
            elif String(parts[1]) == "L":
                var rows = parse_lines(parts[10], d^)
                actual = encode_rows(rows)
            else:
                var rows = decode_rows(parts[10])
                var output = write_all(rows, d)
                actual = hex_bytes(output)
        except:
            failed = True
        var expected_error = String(parts[11]) == "!"
        if failed != expected_error or (not failed and actual != String(parts[11])):
            print("FAIL golden", parts[0], "error", failed, "expected", parts[11], "actual", actual)
            raise Error("CPython golden mismatch")
        count += 1
    if count < 50:
        raise Error("too few golden vectors")
    print("PASS golden", count)


def main() raises:
    replay()
