# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
from std.sys import argv
from uregex import Pattern
from uregex.pattern import to_codepoints


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: uregex-cli PATTERN TEXTS_FILE   (texts separated by NUL)")
        return
    var pat = Pattern(String(args[1]))
    var data: String
    with open(String(args[2]), "r") as f:
        data = f.read()
    var texts = data.split("\0")
    for t in texts:
        var cps = to_codepoints(t)
        var line = String("")
        for m in pat.findall_cps(cps):
            line += String(m.start) + "," + String(m.end) + " "
        print(line)
