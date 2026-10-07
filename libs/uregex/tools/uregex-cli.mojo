# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
from std.sys import argv
from uregex import Pattern


def main() raises:
    var args = argv()
    var bytes_mode = len(args) == 4 and String(args[1]) == "--bytes"
    var a = 2 if bytes_mode else 1
    if len(args) < a + 2:
        print("usage: uregex-cli [--bytes] PATTERN TEXTS_FILE   (texts separated by NUL)")
        return
    var pat = Pattern(String(args[a]))
    var data: String
    with open(String(args[a + 1]), "r") as f:
        data = f.read()
    var texts = data.split("\0")
    for t in texts:
        var text = String(t)
        var line = String("")
        if bytes_mode:
            for m in pat.findall_spans(text):
                line += String(m.start) + "," + String(m.end) + " "
        else:
            for m in pat.findall_cps_offsets(text):
                line += String(m.start) + "," + String(m.end) + " "
        print(line)
