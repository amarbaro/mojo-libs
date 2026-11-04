# Pick the newest release that satisfies a constraint.
from semver import parse


def main() raises:
    var tags = ["1.2.0", "1.10.0-rc.1", "1.9.3", "2.0.0-alpha", "1.10.0"]
    var best = parse("0.0.0")
    for t in tags:
        var v = parse(t)
        if v.match("<2.0.0") and not v.prerelease and best < v:
            best = v^
    print("newest stable < 2.0.0:", best)
