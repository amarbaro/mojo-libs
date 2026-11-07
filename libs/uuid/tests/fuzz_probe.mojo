from uuid import UUID
from std.sys import argv

def main() raises:
    var text = open(argv()[1], "r").read()
    var lines = text.split("\n")
    if text.endswith("\n") and len(lines) > 0:
        _ = lines.pop()
    for line in lines:
        try:
            print("ok", UUID(String(line)).__str__())
        except e:
            print("err", e)
