# gen ROOT LIST: print the library table, one row per checkout named in LIST (paths relative to ROOT).
# Fails loud: "FAIL <repo>: <reason>", exit 1.
from std.sys import argv, exit
from toml import parse


def row(root: String, dir: String) raises -> String:
    var doc = parse(open(root + "/" + dir + "/pyproject.toml", "r").read())
    var p = doc["project"]
    var name = String(p["name"].as_string())
    var home = String("https://github.com/amarbaro/") + name
    if p.contains("urls") and p["urls"].contains("Homepage"):
        home = String(p["urls"]["Homepage"].as_string())
    var pin = String()
    var deps = String()
    for i in range(p["dependencies"].len()):
        var d = String(p["dependencies"][i].as_string())
        if d.startswith("mojo") or d.startswith("max"):
            pin = d if pin == "" or d.startswith("max") else pin
    if doc.contains("tool") and doc["tool"].contains("mojo") and doc["tool"]["mojo"].contains("deps"):
        var ds = doc["tool"]["mojo"]["deps"]
        for i in range(ds.len()):
            deps += (", " if deps != "" else "") + String(ds[i].as_string())
    if pin == "":
        raise Error("FAIL " + dir + ": no mojo or max pin in [project].dependencies")
    var slug = String(home.removeprefix("https://github.com/"))
    return ("| [" + name + "](" + home + ") | " + String(p["description"].as_string()) + " | " + String(p["version"].as_string())
        + " | `" + pin + "` | " + (deps if deps != "" else "-") + " | ![ci](https://github.com/" + slug
        + "/actions/workflows/ci.yml/badge.svg?branch=main) |")


def main() raises:
    var a = argv()
    if len(a) != 3:
        print("usage: gen ROOT LIST")
        exit(2)
    var out = String("| library | what | version | toolchain | our deps | ci |\n|---|---|---|---|---|---|\n")
    try:
        for line in open(String(a[2]), "r").read().split("\n"):
            var l = String(line.strip())
            if l == "" or l.startswith("#"):
                continue
            out += row(String(a[1]), l) + "\n"
    except e:
        var m = String(e)
        print(m if m.startswith("FAIL") else "FAIL gen: " + m)
        exit(1)
    print(out, end="")
