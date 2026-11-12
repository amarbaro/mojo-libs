"""Real ClientHellos (tests/vectors/ch_*.hex, captured from openssl, curl, python ssl and Vivaldi): parse them,
answer them with Server12, and fuzz them. Run from the repo root."""
from tutil import *
from tls.tls12.msg import *
from tls.tls12.wire import Rd, bytes_of, str_of


def unhex(s: String) raises -> List[UInt8]:
    var o = List[UInt8]()
    var b = s.as_bytes()
    for i in range(0, len(b) - 1, 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        o.append(UInt8(((hi - 48 if hi < 58 else hi - 87) << 4) | (lo - 48 if lo < 58 else lo - 87)))
    return o^


def load(name: String) raises -> List[UInt8]:
    return unhex(String(open("tests/vectors/ch_" + name + ".hex", "r").read().strip()))


def main() raises:
    var t = T()
    var cfg = make_cfg()
    var names = ["openssl12", "openssl13", "curl12", "curl13", "python", "vivaldi"]
    var seed = UInt64(0x9E3779B97F4A7C15)
    for n in names:
        var raw = load(n)
        t.check(n + ": is one handshake record", raw[0] == 22 and len(raw) == 5 + (Int(raw[3]) << 8 | Int(raw[4])))
        var ch = parse_client_hello(List[UInt8](Span(raw)[9:]))
        var is13 = n.endswith("13") or n == "python" or n == "vivaldi"
        t.check(n + ": offers TLS 1.2" + (" and 1.3" if is13 else " only"), ch.offers12() and ch.offers13() == is13)
        t.check(n + ": extended master secret, renegotiation_info", ch.ems and ch.ri and not ch.ri_bad)
        t.check(n + ": SNI and a usable suite, group, sigalg", ch.sni == "localhost" and choose_suite(ch, True, True) != 0 and choose_group(ch) != 0 and 0x0403 in ch.sigalgs)
        if n == "vivaldi":
            var grease = False
            for s in ch.suites:
                grease = grease or (s & 0x0F0F) == 0x0A0A
            t.check("vivaldi: sends GREASE and X25519MLKEM768, we skip both", grease and 0x11EC in ch.groups and choose_group(ch) == G_X25519)
        # a server answers it: ServerHello parses, suite was offered, sentinel iff the client offered 1.3
        var s = Sv(cfg)
        s.feed(raw)
        var fl = s.cn.take_output()
        var r = Rd(fl.copy())
        _ = r.take(5)
        var typ = r.u8()
        var sh = parse_server_hello(r.vec24().d.copy())
        t.check(n + ": ServerHello answers it", typ == H_SH and sh.suite in ch.suites and sh.ems and sh.ri and sentinel(sh.random) == is13)
        # fuzz the real hello: flip, replace and truncate bytes; never a crash, never a hang
        var survived = 0
        for it in range(400):
            var m = raw.copy()
            for _ in range(1 + it % 3):
                seed ^= seed << 13
                seed ^= seed >> 7
                seed ^= seed << 17
                m[Int(seed % UInt64(len(m)))] = UInt8((seed >> 24) & 255)
            if it % 4 == 0:
                m = List[UInt8](Span(m)[0 : 1 + Int((seed >> 12) % UInt64(len(m) - 1))])
            var f = Sv(cfg)
            try:
                f.feed(m)
            except:
                pass
            survived += 1
        t.check(n + ": 400 mutated copies survived", survived == 400)
    t.done()
