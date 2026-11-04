"""Semantic Versioning 2.0.0, with the exact rules of Python semver 3.0 (parse, precedence, bump, match)."""


def _digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def _ident_char(c: UInt8) -> Bool:
    return _digit(c) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45


def _all_digits(s: StringSlice[_]) -> Bool:
    for c in s.as_bytes():
        if not _digit(c):
            return False
    return True


def _number(s: StringSlice[_]) raises -> Int:
    """0 or a digit run without a leading zero (fits in Int)."""
    var b = s.as_bytes()
    if len(b) == 0 or not _all_digits(s) or (len(b) > 1 and b[0] == 48) or len(b) > 18:
        raise Error("bad number")
    var n = 0
    for c in b:
        n = n * 10 + Int(c - 48)
    return n


def _check_idents(s: StringSlice[_], pre: Bool) raises:
    """Dot-separated identifiers; prerelease numeric ones may not have a leading zero."""
    for part in s.split("."):
        var b = part.as_bytes()
        if len(b) == 0:
            raise Error("empty identifier")
        for c in b:
            if not _ident_char(c):
                raise Error("bad character")
        if pre and _all_digits(part) and len(b) > 1 and b[0] == 48:
            raise Error("leading zero")


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
        var two = String(expr[byte = 0 : min(2, len(b))])
        if two in [">=", "<=", "==", "!="]:
            op = two
            rest = 2
        elif len(b) > 0 and (b[0] == 62 or b[0] == 60):
            op = String(expr[byte=0:1])
            rest = 1
        elif len(b) > 0 and _digit(b[0]):
            op = "=="
        else:
            raise Error("match_expr parameter should be in format <op><ver>, where <op> is one of ['<', '>', '==', '<=', '>=', '!=']. You provided: '", expr, "'")
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


def _nat_cmp(a: String, b: String) -> Int:
    """Python semver's prerelease order: numeric parts as numbers, numbers before text."""
    var pa = a.split(".")
    var pb = b.split(".")
    for i in range(min(len(pa), len(pb))):
        var x = pa[i]
        var y = pb[i]
        var nx = x.byte_length() > 0 and _all_digits(x)
        var ny = y.byte_length() > 0 and _all_digits(y)
        var r = 0
        if nx and ny:
            var lx = x.byte_length()
            var ly = y.byte_length()
            # digit strings without leading zeros: longer is larger, same length compares as text
            r = (-1 if lx < ly else 1) if lx != ly else (0 if x == y else (-1 if x < y else 1))
        elif nx:
            r = -1
        elif ny:
            r = 1
        else:
            r = 0 if x == y else (-1 if x < y else 1)
        if r != 0:
            return r
    return 0 if len(pa) == len(pb) else (-1 if len(pa) < len(pb) else 1)


def _increment(s: String) -> String:
    """Python semver _increment_string: bump the last digit run, Python's slicing quirk included."""
    var b = s.as_bytes()
    var end = len(b)
    while end > 0 and not _digit(b[end - 1]):
        end -= 1
    if end == 0:
        return s.copy()
    var start = end
    while start > 0 and _digit(b[start - 1]):
        start -= 1
    var n = 0
    for k in range(start, end):
        n = n * 10 + Int(b[k] - 48)
    var nxt = String(n + 1)
    var cut = max(end - nxt.byte_length(), start)
    return String(s[byte=0:cut]) + nxt + String(s[byte=end:])


def parse(s: String) raises -> Version:
    """Strict SemVer 2.0 (major.minor.patch required), as Python semver Version.parse."""
    try:
        var core_end = s.byte_length()
        var plus = s.find("+")
        var dash = s.find("-")
        if plus >= 0:
            core_end = plus
        if dash >= 0 and dash < core_end:
            core_end = dash
        var nums = String(s[byte=0:core_end]).split(".")
        if len(nums) != 3:
            raise Error("parts")
        var pre = String()
        var build = String()
        if dash >= 0 and dash == core_end:
            var pe = plus if plus >= 0 else s.byte_length()
            pre = String(s[byte = dash + 1 : pe])
            _check_idents(pre, True)
        if plus >= 0:
            build = String(s[byte = plus + 1 :])
            _check_idents(build, False)
        return Version(_number(nums[0]), _number(nums[1]), _number(nums[2]), pre^, build^)
    except:
        raise Error(s, " is not valid SemVer string")


def is_valid(s: String) -> Bool:
    try:
        _ = parse(s)
        return True
    except:
        return False


def compare(a: String, b: String) raises -> Int:
    return parse(a).compare(parse(b))
