"""Oracle: Python semver 3.0.4. `oracle.py --list` names scenarios; `oracle.py NAME DIR` prints its lines."""
import os, sys
import semver
D = os.path.join(os.path.dirname(__file__), "..", "tests", "data")
def lines(f): return [l.rstrip("\n") for l in open(os.path.join(D, f))]
def p(s):
    try: return str(semver.Version.parse(s))
    except ValueError: return "ERR"
def parse(_):
    for f in ("valid.txt", "invalid.txt", "random.txt"):
        for s in lines(f): print("parse", repr(s), p(s))
def order(_):
    vs = lines("valid.txt") + lines("random.txt")
    for a in vs[:60]:
        print("cmp", a, " ".join(str(semver.Version.parse(a).compare(b)) for b in vs[:60]))
    for a in vs: print("cmp1", a, semver.Version.parse(a).compare(vs[0]), semver.Version.parse(a).compare("1.0.0"))
def match(_):
    for a in lines("valid.txt"):
        out = []
        for e in lines("exprs.txt"):
            try: out.append("T" if semver.Version.parse(a).match(e) else "F")
            except ValueError: out.append("E")
        print("match", a, "".join(out))
def bump(_):
    for a in lines("valid.txt") + lines("random.txt")[:100]:
        v = semver.Version.parse(a)
        print("bump", a, v.bump_major(), v.bump_minor(), v.bump_patch(), v.bump_prerelease(), v.bump_prerelease("alpha"),
              v.bump_prerelease(""), v.bump_build(), v.bump_build(""), v.finalize_version())
S = {"parse": parse, "order": order, "match": match, "bump": bump}
if sys.argv[1] == "--list": print("\n".join(S))
else: S[sys.argv[1]](sys.argv[2])
