# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
from .parser import Parser
from .vm import Program, utf8_len


@fieldwise_init
struct Match(Copyable, Movable, ImplicitlyCopyable):
    var start: Int
    var end: Int


def to_codepoints(s: StringSlice) -> List[Int]:
    var out = List[Int]()
    for c in s.codepoints():
        out.append(Int(c.to_u32()))
    return out^


def from_codepoints(cps: List[Int], start: Int, end: Int) -> String:
    var s = String("")
    for i in range(start, end):
        s += String(Codepoint.from_u32(UInt32(cps[i])).value())
    return s^


def _slice(text: String, start: Int, end: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=text.as_bytes()[start:end]))


struct Pattern(Copyable, Movable):
    """Matches on UTF-8 bytes. `Match` offsets are byte offsets into the input String."""

    var prog: Program
    var source: String

    def __init__(out self, pattern: String) raises:
        var p = Parser(pattern)
        var ast = p.parse()
        self.prog = Program(ast)
        self.source = pattern

    def groups(self) -> Int:
        """Number of capture groups."""
        return self.prog.groups

    def group_index(self, name: String) raises -> Int:
        for i in range(1, len(self.prog.names)):
            if self.prog.names[i] == name:
                return i
        raise Error("uregex: no group named " + name)

    def new_slots(self) -> List[Int32]:
        return List[Int32](length=2 * (self.prog.groups + 1), fill=-1)

    def search_from(
        self, text: Span[Byte, _], mut stack: List[Int32], mut slots: List[Int32], start: Int
    ) -> Optional[Match]:
        if self.prog.full:
            return self._search[True](text, stack, slots, start)
        return self._search[False](text, stack, slots, start)

    @always_inline
    def _search[full: Bool](
        self, text: Span[Byte, _], mut stack: List[Int32], mut slots: List[Int32], start: Int
    ) -> Optional[Match]:
        var n = len(text)
        var s = start
        if self.prog.has_first:
            while s < n:
                if self.prog.can_start(text[s]):
                    var e = self.prog.exec[full](text, stack, slots, 0, s, False)
                    if e >= 0:
                        return Match(s, e)
                s += utf8_len(text[s])
            return None
        while True:
            var e = self.prog.exec[full](text, stack, slots, 0, s, False)
            if e >= 0:
                return Match(s, e)
            if s >= n:
                return None
            s += utf8_len(text[s])

    def search(self, text: String) -> Optional[Match]:
        var stack = List[Int32]()
        var slots = self.new_slots()
        return self.search_from(text.as_bytes(), stack, slots, 0)

    def findall_spans(self, text: String) -> List[Match]:
        if self.prog.full:
            return self._spans[True](text)
        return self._spans[False](text)

    def _spans[full: Bool](self, text: String) -> List[Match]:
        var bytes = text.as_bytes()
        var n = len(bytes)
        var out = List[Match]()
        var stack = List[Int32]()
        var slots = self.new_slots()
        var pos = 0
        while pos <= n:
            var m = self._search[full](bytes, stack, slots, pos)
            if not m:
                break
            var mm = m.value()
            out.append(mm)
            if mm.end > mm.start:
                pos = mm.end
            elif mm.end < n:
                pos = mm.end + utf8_len(bytes[mm.end])
            else:
                break
        return out^

    def findall_groups(self, text: String) -> List[List[Match]]:
        """Every match as byte spans: [0] the whole match, [i] group i, (-1, -1) when unset."""
        var bytes = text.as_bytes()
        var n = len(bytes)
        var out = List[List[Match]]()
        var stack = List[Int32]()
        var slots = self.new_slots()
        var pos = 0
        while pos <= n:
            for ref v in slots:
                v = -1
            var m = self._search[True](bytes, stack, slots, pos)
            if not m:
                break
            var mm = m.value()
            var row = List[Match](capacity=self.prog.groups + 1)
            row.append(mm)
            for g in range(1, self.prog.groups + 1):
                row.append(Match(Int(slots[2 * g]), Int(slots[2 * g + 1])))
            out.append(row^)
            if mm.end > mm.start:
                pos = mm.end
            elif mm.end < n:
                pos = mm.end + utf8_len(bytes[mm.end])
            else:
                break
        return out^

    def findall_cps_offsets(self, text: String) -> List[Match]:
        """Like `findall_spans`, with codepoint offsets."""
        var bytes = text.as_bytes()
        var out = List[Match]()
        var b = 0
        var cp = 0
        for m in self.findall_spans(text):
            while b < m.start:
                b += utf8_len(bytes[b])
                cp += 1
            var s = cp
            while b < m.end:
                b += utf8_len(bytes[b])
                cp += 1
            out.append(Match(s, cp))
        return out^

    def findall_cps(self, text: List[Int]) -> List[Match]:
        """Compatibility: codepoint input, codepoint offsets."""
        return self.findall_cps_offsets(from_codepoints(text, 0, len(text)))

    def findall(self, text: String) -> List[String]:
        var out = List[String]()
        for m in self.findall_spans(text):
            out.append(_slice(text, m.start, m.end))
        return out^

    def split_keep(self, text: String) -> List[String]:
        var out = List[String]()
        var last = 0
        for m in self.findall_spans(text):
            if m.start > last:
                out.append(_slice(text, last, m.start))
            if m.end > m.start:
                out.append(_slice(text, m.start, m.end))
            last = m.end
        if last < text.byte_length():
            out.append(_slice(text, last, text.byte_length()))
        return out^


def compile(pattern: String) raises -> Pattern:
    return Pattern(pattern)


def search(pattern: String, text: String) raises -> Optional[Match]:
    return Pattern(pattern).search(text)


def findall(pattern: String, text: String) raises -> List[String]:
    return Pattern(pattern).findall(text)


def split_keep(pattern: String, text: String) raises -> List[String]:
    return Pattern(pattern).split_keep(text)
