# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from uregex import Pattern, findall, search, split_keep


def test_unicode_classes() raises:
    assert_equal(len(findall(r"\p{L}+", "héllo 一二 world")), 3)
    assert_equal(findall(r"\p{N}{1,3}", "12345")[0], "123")
    assert_equal(len(findall(r"\P{L}+", "ab12cd")), 1)


def test_case_insensitive_group() raises:
    var r = findall(r"(?i:'s|'t|'ll)", "IT'S 'Ll 't")
    assert_equal(len(r), 3)
    assert_equal(r[0], "'S")


def test_lookahead() raises:
    var r = findall(r"\s+(?!\S)|\s+", "a   b  ")
    assert_equal(r[0], "  ")
    assert_equal(r[1], " ")
    assert_equal(r[2], "  ")


def test_alternation_is_leftmost_first() raises:
    assert_equal(findall("ab|abc", "abc")[0], "ab")


def test_split_keep_covers_text() raises:
    var pieces = split_keep(r"\p{N}+", "ab12cd3")
    assert_equal(len(pieces), 4)
    assert_equal(pieces[1], "12")


def test_search_offsets_are_codepoints() raises:
    var m = search(r"\p{N}+", "一二三42").value()
    assert_equal(m.start, 3)
    assert_equal(m.end, 5)


def test_rejects_unsupported() raises:
    with assert_raises():
        _ = Pattern(r"a*?")
    with assert_raises():
        _ = Pattern(r"(?:a?)*")
    with assert_raises():
        _ = Pattern(r"\bword\b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
