"""Lane 1 gate runner: sym_check VECFILE... checks every line of every vector file, prints PASS/FAIL per kind.
An unknown kind is a failure (a skipped vector is not a pass). See tools/gen_vec.py for the line format."""
from std.collections import Dict
from std.sys import argv, exit
from tls.sym.sha2 import *
from tls.sym.mac import *


def unhex(s: StringSlice) raises -> List[UInt8]:
    var out = List[UInt8]()
    if s == "-":
        return out^
    var b = s.as_bytes()
    for i in range(0, len(b), 2):
        var v = 0
        for j in range(2):
            var c = Int(b[i + j])
            v = v * 16 + (c - 48 if c < 58 else c - 87)
        out.append(UInt8(v))
    return out^


def hash_of(alg: StringSlice, m: Span[UInt8, ImmutAnyOrigin]) raises -> List[UInt8]:
    if alg == "256":
        return sha256(m)
    elif alg == "384":
        return sha384(m)
    elif alg == "512":
        return sha512(m)
    raise Error("alg " + String(alg))


def mac_of(alg: StringSlice, k: Span[UInt8, ImmutAnyOrigin], m: Span[UInt8, ImmutAnyOrigin]) raises -> List[UInt8]:
    if alg == "256":
        return hmac[Sha256](k, m)
    elif alg == "384":
        return hmac[Sha384](k, m)
    return hmac[Sha512](k, m)


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    return len(a) == len(b) and Span(a) == Span(b)


def check(f: List[String]) raises -> Bool:
    var kind = f[0]
    var alg = f[1] if len(f) > 1 else String("")
    if kind == "hash":
        return same(hash_of(alg, unhex(f[2])), unhex(f[3]))
    elif kind == "hmac":
        var got = mac_of(alg, unhex(f[2]), unhex(f[3]))
        var want = unhex(f[4])
        var eq = len(want) <= len(got) and Span(got)[: len(want)] == Span(want)
        return eq == (f[5] == "valid")
    elif kind == "hkdf":
        var ikm = unhex(f[2])
        var salt = unhex(f[3])
        var info = unhex(f[4])
        var n = Int(f[5])
        var ok = f[7] == "valid"
        try:
            var prk = hkdf_extract[Sha256](salt, ikm) if alg == "256" else hkdf_extract[Sha384](salt, ikm)
            var okm = hkdf_expand[Sha256](prk, info, n) if alg == "256" else hkdf_expand[Sha384](prk, info, n)
            return ok and same(okm, unhex(f[6]))
        except:
            return not ok
    elif kind == "hkdfl":
        var sec = unhex(f[2])
        var lab = String(unsafe_from_utf8=unhex(f[3]))
        var ctx = unhex(f[4])
        var o = hkdf_expand_label[Sha256](sec, lab, ctx, Int(f[5])) if alg == "256" else hkdf_expand_label[Sha384](sec, lab, ctx, Int(f[5]))
        return same(o, unhex(f[6]))
    elif kind == "prf":
        var sec = unhex(f[2])
        var lab = String(unsafe_from_utf8=unhex(f[3]))
        var seed = unhex(f[4])
        var o = prf12[Sha256](sec, lab, seed, Int(f[5])) if alg == "256" else prf12[Sha384](sec, lab, seed, Int(f[5]))
        return same(o, unhex(f[6]))
    raise Error("unknown kind " + kind)


def main() raises:
    var passed = Dict[String, Int]()
    var failed = Dict[String, Int]()
    var first = Dict[String, String]()
    for a in range(1, len(argv())):
        var path = String(argv()[a])
        var lines = open(path, "r").read().split("\n")
        for ln in range(len(lines)):
            if lines[ln].byte_length() == 0:
                continue
            var f = List[String]()
            for p in lines[ln].split(" "):
                f.append(String(p))
            var ok = False
            var err = String()
            try:
                ok = check(f)
            except e:
                err = String(e)
            var k = f[0]
            if ok:
                passed[k] = passed.get(k, 0) + 1
            else:
                failed[k] = failed.get(k, 0) + 1
                if k not in first:
                    first[k] = path + ":" + String(ln + 1)
                if failed[k] <= 4:
                    print("  fail", path + ":" + String(ln + 1), "alg", f[1], "len", lines[ln].byte_length(), err)
    var bad = 0
    for e in passed.items():
        var nf = failed.get(e.key, 0)
        if nf == 0:
            print("PASS", e.key, e.value)
    for e in failed.items():
        bad += e.value
        print("FAIL", e.key, ":", e.value, "failed, first at", first[e.key])
    if bad > 0:
        exit(1)
