from uuid import *
def main() raises:
    var ns = materialize[NAMESPACE_DNS]()
    var u = uuid3(ns, "python.org")
    print(u.__str__())