# Every public call once, plus the README example.
from semver import Version, parse, is_valid, compare


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("FAIL api: " + what)


def main() raises:
    var v = parse("1.2.3-rc.1+build.5")
    check(v.major == 1 and v.minor == 2 and v.patch == 3, "fields")
    check(v.prerelease == "rc.1" and v.build == "build.5", "pre/build")
    check(String(v) == "1.2.3-rc.1+build.5", "str")
    check(v < parse("1.2.3"), "pre < release")
    check(parse("1.0.0+a") == parse("1.0.0+b"), "build ignored")
    check(v.match(">=1.2.3-rc.0") and not v.match(">1.2.3"), "match")
    check(String(v.bump_prerelease()) == "1.2.3-rc.2", "bump_prerelease")
    check(String(v.bump_minor()) == "1.3.0", "bump_minor")
    check(String(v.bump_build()) == "1.2.3-rc.1+build.6", "bump_build")
    check(String(v.finalize_version()) == "1.2.3", "finalize")
    check(is_valid("1.0.0") and not is_valid("01.0.0"), "is_valid")
    check(compare("2.0.0", "10.0.0") == -1, "compare")
    var raised = False
    try:
        _ = parse("1.2")
    except:
        raised = True
    check(raised, "strict parse")
    print("PASS api")
