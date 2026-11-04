"""Semantic Versioning 2.0.0, with the exact rules of Python semver 3.0 (parse, precedence, bump, match)."""


def _digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def _ident_char(c: UInt8) -> Bool:
    return _digit(c) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45


def _check_idents(b: Span[UInt8, _], pre: Bool) raises:
    """Dot-separated identifiers, scanned in place; prerelease numeric ones may not have a leading zero."""
    var i = 0
    while True:
        var start = i
        var digits = True
        while i < len(b) and b[i] != 46:
            if not _ident_char(b[i]):
                raise Error("bad character")
            digits = digits and _digit(b[i])
            i += 1
        if i == start:
            raise Error("empty identifier")
        if pre and digits and i - start > 1 and b[start] == 48:
            raise Error("leading zero")
        if i == len(b):
            return
        i += 1


@fieldwise_init
struct Version(Copyable, Equatable, Movable, Writable):
    """major.minor.patch[-prerelease][+build]. Empty prerelease/build mean absent."""

    var major: Int
    var minor: Int
    var patch: Int
    var prerelease: String
    var build: String

    def write_to(self, mut w: Some[Writer]):
        w.write(self.major, ".", self.minor, ".", self.patch)
        if self.prerelease:
            w.write("-", self.prerelease)
        if self.build:
            w.write("+", self.build)

    def __eq__(self, o: Self) -> Bool:
        return self.compare(o) == 0

    def __lt__(self, o: Self) -> Bool:
        return self.compare(o) < 0

    def __le__(self, o: Self) -> Bool:
        return self.compare(o) <= 0

    def __gt__(self, o: Self) -> Bool:
        return self.compare(o) > 0

    def __ge__(self, o: Self) -> Bool:
        return self.compare(o) >= 0

    def compare(self, o: Self) -> Int:
        """-1, 0 or 1 by SemVer precedence; build metadata is ignored."""
        for p in [(self.major, o.major), (self.minor, o.minor), (self.patch, o.patch)]:
            if p[0] != p[1]:
                return -1 if p[0] < p[1] else 1
        var r = _nat_cmp(self.prerelease, o.prerelease)
        if r == 0:
            return 0
        if not self.prerelease:
            return 1
        if not o.prerelease:
            return -1
        return r

    def match(self, expr: String) raises -> Bool:
        """`<op>version` with op in < > <= >= == != (bare version means ==)."""
        var b = expr.as_bytes()
        var op = String()
        var rest = 0
        var two = String(expr[byte=0:2]) if len(b) >= 2 and b[0] < 128 and b[1] < 128 else String()
        if two in [">=", "<=", "==", "!="]:
            op = two
            rest = 2
        elif len(b) > 0 and (b[0] == 62 or b[0] == 60):
            op = String(expr[byte=0:1])
            rest = 1
        elif len(b) > 0 and _digit(b[0]):
            op = "=="
        else:
            raise Error("match_expr parameter should be in format <op><ver>, where <op> is one of ['<', '>', '==', '<=', '>=', '!=']. You provided: ", _py_str_repr(expr))
        var c = self.compare(parse(String(expr[byte=rest:])))
        if op == ">":
            return c == 1
        if op == "<":
            return c == -1
        if op == "==":
            return c == 0
        if op == "!=":
            return c != 0
        if op == ">=":
            return c >= 0
        return c <= 0

    def bump_major(self) -> Self:
        return Self(self.major + 1, 0, 0, "", "")

    def bump_minor(self) -> Self:
        return Self(self.major, self.minor + 1, 0, "", "")

    def bump_patch(self) -> Self:
        return Self(self.major, self.minor, self.patch + 1, "", "")

    def bump_prerelease(self, token: String = "rc") -> Self:
        var p = self.prerelease.copy() if self.prerelease else ("0" if not token else token + ".0")
        return Self(self.major, self.minor, self.patch, _increment(p), "")

    def bump_build(self, token: String = "build") -> Self:
        var p = self.build.copy() if self.build else ("0" if not token else token + ".0")
        return Self(self.major, self.minor, self.patch, self.prerelease.copy(), _increment(p))

    def finalize_version(self) -> Self:
        return Self(self.major, self.minor, self.patch, "", "")


def _part(b: Span[UInt8, _], i: Int) -> Int:
    """End of the dot-separated part starting at i."""
    var j = i
    while j < len(b) and b[j] != 46:
        j += 1
    return j


def _py_str_repr(s: String) -> String:
    """Python repr() of a str, for error texts: single quotes unless the text has one and no double quote."""
    var q = "'"
    if "'" in s and not '"' in s:
        q = '"'
    var out = q
    for c in s.codepoint_slices():
        if c == "\\":
            out += "\\\\"
        elif c == q:
            out += "\\" + q
        elif c == "\n":
            out += "\\n"
        else:
            out += c
    return out + q


def _nat_cmp(a: String, b: String) -> Int:
    """Python semver's prerelease order: numeric parts as numbers, numbers before text. No allocation."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var i = 0
    var j = 0
    while True:
        var ie = _part(x, i)
        var je = _part(y, j)
        var nx = ie > i
        var ny = je > j
        for k in range(i, ie):
            nx = nx and _digit(x[k])
        for k in range(j, je):
            ny = ny and _digit(y[k])
        var r = 0
        if nx and ny and ie - i != je - j:
            r = -1 if ie - i < je - j else 1
        elif nx and not ny:
            r = -1
        elif ny and not nx:
            r = 1
        else:  # both text, or equal-length digit runs: byte order
            var k = 0
            while r == 0 and i + k < ie and j + k < je:
                if x[i + k] != y[j + k]:
                    r = -1 if x[i + k] < y[j + k] else 1
                k += 1
            if r == 0 and ie - i != je - j:
                r = -1 if ie - i < je - j else 1
        if r != 0:
            return r
        var x_end = ie >= len(x)
        var y_end = je >= len(y)
        if x_end or y_end:
            return 0 if x_end and y_end else (-1 if x_end else 1)
        i = ie + 1
        j = je + 1


def _increment(s: String) -> String:
    """Python semver _increment_string: bump the last digit run, Python's slicing quirk included.
    The run is incremented as decimal text, so any length works (Python ints are unbounded)."""
    var b = s.as_bytes()
    var end = len(b)
    while end > 0 and not _digit(b[end - 1]):
        end -= 1
    if end == 0:
        return s.copy()
    var start = end
    while start > 0 and _digit(b[start - 1]):
        start -= 1
    while start < end - 1 and b[start] == 48:  # int() drops leading zeros
        start += 1
    var digits = List[UInt8](b[start:end])
    var k = len(digits) - 1
    while k >= 0 and digits[k] == 57:
        digits[k] = 48
        k -= 1
    if k >= 0:
        digits[k] += 1
    else:
        digits.insert(0, 49)
    var nxt = String(unsafe_from_utf8=digits)
    var lead = start
    while lead > 0 and b[lead - 1] == 48:
        lead -= 1
    start = lead
    var cut = max(end - nxt.byte_length(), start)
    return String(s[byte=0:cut]) + nxt + String(s[byte=end:])


def _core(b: Span[UInt8, _], mut i: Int) raises -> Int:
    """One core number at i: 0 or digits without a leading zero, at most 18 digits."""
    var start = i
    var n = 0
    while i < len(b) and _digit(b[i]):
        n = n * 10 + Int(b[i] - 48)
        i += 1
    if i == start or (i - start > 1 and b[start] == 48) or i - start > 18:
        raise Error("bad number")
    return n


def parse(s_in: String) raises -> Version:
    """Strict SemVer 2.0 (major.minor.patch required), as Python semver Version.parse. One scan; the only
    allocations are the prerelease and build strings themselves. One trailing newline is accepted, as
    Python's `$` does."""
    var n = s_in.byte_length()
    var s = String(s_in[byte = 0 : n - 1]) if n > 0 and s_in.as_bytes()[n - 1] == 10 else s_in.copy()
    try:
        var b = s.as_bytes()
        var i = 0
        var major = _core(b, i)
        if i >= len(b) or b[i] != 46:
            raise Error("parts")
        i += 1
        var minor = _core(b, i)
        if i >= len(b) or b[i] != 46:
            raise Error("parts")
        i += 1
        var patch = _core(b, i)
        var pre = String()
        var build = String()
        if i < len(b) and b[i] == 45:
            var start = i + 1
            i = start
            while i < len(b) and b[i] != 43:
                i += 1
            _check_idents(b[start:i], True)
            pre = String(s[byte=start:i])
        if i < len(b) and b[i] == 43:
            _check_idents(b[i + 1 :], False)
            build = String(s[byte = i + 1 :])
            i = len(b)
        if i != len(b):
            raise Error("trailing")
        return Version(major, minor, patch, pre^, build^)
    except:
        raise Error(s_in, " is not valid SemVer string")


def is_valid(s: String) -> Bool:
    try:
        _ = parse(s)
        return True
    except:
        return False


def compare(a: String, b: String) raises -> Int:
    return parse(a).compare(parse(b))
