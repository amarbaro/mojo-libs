from csv import *
from test_golden import unhex, encode_rows, hex_bytes
from std.testing import assert_equal


def main() raises:
    var tab = Dialect.excel_tab()
    assert_equal(tab.delimiter, UInt8(9))
    var unix = Dialect.unix_dialect()
    assert_equal(unix.quoting, QUOTE_ALL)
    assert_equal(hex_bytes(unix.lineterminator), "0a")
    var data = unhex("612c22620d0a63220d0a642c650a")
    var reader = Reader(Dialect.excel())
    var rows = reader.read_all(Span(data))
    assert_equal(encode_rows(rows), "s61,s620d0a63/s64,s65")
    assert_equal(reader.line_num, 3)
    data.clear()
    assert_equal(encode_rows(rows), "s61,s620d0a63/s64,s65")
    var output = write_all(rows, tab)
    assert_equal(hex_bytes(output), "610922620d0a63220d0a6409650d0a")
    var empty = CsvField()
    assert_equal(empty.is_null, False)
    assert_equal(len(empty.data), 0)
    var null = CsvField(unhex("616263"), True)
    var row = List[CsvField]()
    row.append(null^)
    row.append(empty^)
    var all_rows = List[List[CsvField]]()
    all_rows.append(row^)
    assert_equal(hex_bytes(write_all(all_rows, Dialect.excel())), "2c0d0a")
    print("PASS api")
