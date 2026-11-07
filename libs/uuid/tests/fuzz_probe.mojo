from uuid import UUID
from std.sys import argv

def main() raises:
    var text = open(argv()[1], "r").read()
    for line in text.split("\n"):
        try:
            print("ok", UUID(String(line)).__str__())
        except e:
            print("err", e)
