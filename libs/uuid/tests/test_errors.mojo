"""Error kind and text from CPython Lib/uuid.py v3.14.0.
Source: https://github.com/python/cpython/blob/v3.14.0/Lib/uuid.py
Integer literal errors are emitted by int(hex,16) at uuid.py line 220.
"""
from uuid import UUID, UUIDError
from support import check
from std.collections import Array

def expect_parse(text: String, message: String) raises:
    try:
        _ = UUID(text)
    except e:  # UUIDError retains CPython kind separately from its text.
        check(e.kind == "ValueError", "parse kind")
        check(e.message == message, text + ": " + e.message)
        return
    raise Error("accepted invalid UUID " + text)

def expect_version(version: Int) raises:
    try:
        _ = UUID("00000000000000000000000000000000", version)
    except e:
        check(e.kind == "ValueError", "version kind")
        check(e.message == "illegal version number", "version text")  # CPython L257
        return
    raise Error("accepted illegal version")

def error_tests() raises:
    try:
        _ = UUID()
    except e:
        check(e.kind == "TypeError", "missing input kind")
        check(e.message == "one of the hex, bytes, bytes_le, fields, or int arguments must be given", "missing input text")  # CPython L211-212
    else:
        raise Error("accepted no input")
    # CPython L218-219: codepoint length after strip and replace.
    for text in ["", "a", "0" * 31, "0" * 33, "é" * 31]:
        expect_parse(text, "badly formed hexadecimal UUID string")
    # CPython L220: int(hex, 16), invalid literals (copy complete kind/text).
    expect_parse("g" * 32, "invalid literal for int() with base 16: 'gggggggggggggggggggggggggggggggg'")
    expect_parse("@" * 32, "invalid literal for int() with base 16: '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'")
    expect_parse("é" * 32, "invalid literal for int() with base 16: 'éééééééééééééééééééééééééééééééé'")
    expect_parse("0" * 31 + "_", "invalid literal for int() with base 16: '0000000000000000000000000000000_'")
    expect_parse("_" + "0" * 31, "invalid literal for int() with base 16: '_0000000000000000000000000000000'")
    expect_parse("0" * 31 + chr(0), "invalid literal for int() with base 16: '" + "0" * 31 + "\\x00'")
    expect_parse("0" * 15 + chr(11) + "0" * 16, "invalid literal for int() with base 16: '" + "0" * 15 + "\\x0b" + "0" * 16 + "'")
    expect_parse("0" * 15 + chr(12) + "0" * 16, "invalid literal for int() with base 16: '" + "0" * 15 + "\\x0c" + "0" * 16 + "'")
    expect_parse("0" * 31 + chr(127), "invalid literal for int() with base 16: '" + "0" * 31 + "\\x7f'")
    # CPython L216-220: accepted forms, including int() grammar.
    check(UUID("urn:uuid:{6ba7b810-9dad-11d1-80b4-00c04fd430c8}").hex() == "6ba7b8109dad11d180b400c04fd430c8")
    for text in ["{{00000000000000000000000000000000}", "+" + "0" * 31, " " + "0" * 30 + " ", "0_" + "0" * 30, "0x" + "0" * 30, "0x_" + "0" * 29, "0X_" + "0" * 29, "+0x_" + "0" * 28, "+0X_" + "0" * 28, "0" * 16 + "urn:uuid:" + "0" * 16]:
        check(UUID(text).int() == 0, "accepted form: " + text)
    # CPython L222-223, L229-230: both byte lengths and their own messages.
    for length in [0, 15, 17]:
        var data = List[UInt8](length=length, fill=0)
        for little in [False, True]:
            try:
                _ = UUID(Span(data), little_endian=little)
            except e:
                check(e.kind == "ValueError")
                check(e.message == ("bytes_le is not a 16-char string" if little else "bytes is not a 16-char string"))
            else:
                raise Error("accepted wrong byte length")
    # CPython L234-249: field count and both boundaries of all six ranges.
    var short = Array[Int, 5](fill=0)
    try:
        _ = UUID.from_fields(Span(short))
    except e:
        check(e.kind == "ValueError")
        check(e.message == "fields is not a 6-tuple")  # CPython L235
    else:
        raise Error("accepted five fields")
    var widths: Array[Int, 6] = [32, 16, 16, 8, 8, 48]
    # Exact messages copied from CPython L239,241,243,245,247,249.
    var messages = ["field 1 out of range (need a 32-bit value)", "field 2 out of range (need a 16-bit value)", "field 3 out of range (need a 16-bit value)", "field 4 out of range (need an 8-bit value)", "field 5 out of range (need an 8-bit value)", "field 6 out of range (need a 48-bit value)"]
    for index in range(6):
        for bad in [-1, 1 << widths[index]]:
            var fields = Array[Int, 6](fill=0)
            fields[index] = bad
            try:
                _ = UUID.from_fields(Span(fields))
            except e:
                check(e.kind == "ValueError")
                check(e.message == messages[index])
            else:
                raise Error("accepted out-of-range field")
    # CPython L253-254: signed/range checked decimal adapter for UInt128.
    for bad in ["-1", "340282366920938463463374607431768211456"]:
        try:
            _ = UUID.from_int(bad)
        except e:
            check(e.kind == "ValueError")
            check(e.message == "int is out of range (need a 128-bit value)")
        else:
            raise Error("accepted out-of-range int")
    check(UUID.from_int("340282366920938463463374607431768211455").hex() == "f" * 32)
    for version in [-1, 0, 9]:
        expect_version(version)
    for version in range(1, 9):
        check(UUID("f" * 32, version).version() == version)
    print("PASS CPython 3.14 constructor forms, kinds, texts and ranges")

def main() raises:
    error_tests()
