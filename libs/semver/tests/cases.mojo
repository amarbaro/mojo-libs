# The Mojo side of tools/oracle.py: `cases SCENARIO DIR` prints the same lines.
from std.sys import argv
from semver import Version, parse


def lines(f: String) raises -> List[String]:
    var out = List[String]()
    with open("tests/data/" + f, "r") as h:
        var t = h.read()
        for l in t.split("\n"):
            out.append(String(l))
    _ = out.pop()  # trailing newline
    return out^


def repr(s: String) -> String:
    return "'" + s + "'"


def p(s: String) -> String:
    try:
        return String(parse(s))
    except:
        return "ERR"


def py_repr(s: String) -> String:
    return "'" + s.replace("\n", "\\n") + "'"


def main() raises:
    var c = argv()[1]
    if c == "errtext":
        var v = parse("1.0.0")
        var es: List[String] = ["~1.0.0", "x'y", "~ü", ">é1.0.0", "a\\b"]
        for e in es:
            try:
                _ = v.match(e)
                print("errtext none")
            except ex:
                print("errtext", String(ex))
        return
    if c == "edge":
        var edge: List[String] = ["1.0.0-x.0099a", "1.0.0-rc.00a9", "1.2.3\n", "1.2.3-rc.1+b\n", "1.2.3\n\n", "1.0.0-rc.99999999999999999999", "1.0.0-rc.0099", "1.0.0-x.000", "1.0.0-9.9.9", "1.0.0-a999999999999999999999999"]
        for s in edge:
            var out = p(s)
            if out != "ERR":
                var v = parse(s)
                out += " " + String(v.bump_prerelease()) + " " + String(v.bump_build())
            print("edge", py_repr(s), out)
        return
    if c == "parse":
        for f in ["valid.txt", "invalid.txt", "random.txt"]:
            for s in lines(f):
                print("parse", repr(s), p(s))
    elif c == "order":
        var vs = lines("valid.txt") + lines("random.txt")
        for i in range(60):
            var row = String()
            var a = parse(vs[i])
            for j in range(60):
                if j:
                    row += " "
                row += String(a.compare(parse(vs[j])))
            print("cmp", vs[i], row)
        var first = parse(vs[0])
        var one = parse("1.0.0")
        for s in vs:
            var a = parse(s)
            print("cmp1", s, a.compare(first), a.compare(one))
    elif c == "match":
        var ex = lines("exprs.txt")
        for s in lines("valid.txt"):
            var v = parse(s)
            var out = String()
            for e in ex:
                try:
                    out += "T" if v.match(e) else "F"
                except:
                    out += "E"
            print("match", s, out)
    elif c == "bump":
        var r = lines("random.txt")
        var vs = lines("valid.txt")
        for k in range(100):
            vs.append(r[k])
        for s in vs:
            var v = parse(s)
            print("bump", s, v.bump_major(), v.bump_minor(), v.bump_patch(), v.bump_prerelease(), v.bump_prerelease("alpha"),
                  v.bump_prerelease(""), v.bump_build(), v.bump_build(""), v.finalize_version())
