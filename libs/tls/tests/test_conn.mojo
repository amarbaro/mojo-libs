# Gate: our client against our server (no recorded bytes). 3 cipher suites x 4 key exchanges (x25519, HRR to P-256, P-384, x448), direct P-384 and x448 shares,
# data both ways, KeyUpdate both ways, automatic KeyUpdate at the key limit, record_size_limit, ALPN, SNI, byte-wise
# feeding, every alert the handshake can raise, and fuzzing of both state machines.
from tls.asym import x25519_base, x448_base, p384_public
from tls.tls13.client import Client13, default_hello
from tls.tls13.conn import *
from tls.tls13.keysched import traffic_key, traffic_iv
from tls.tls13.messages import *
from tls.tls13.record import Cipher, seal_all, HS, APP, ALERT
from tls.tls13.server import Server13, ServerConfig
from tls.tls13.verify import Verifier, Signer
from chk import T
from rec import RecSigner, RecVerifier, Refuse


def fill(n: Int, b: Int) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(b))


def pattern(n: Int, salt: Int) -> List[UInt8]:
    var o = List[UInt8](capacity=n)
    for i in range(n):
        o.append(UInt8((i * 7 + salt) & 0xFF))
    return o^


def signer(scheme: Int = 0x0403) -> RecSigner:
    var chain = List[List[UInt8]]()
    chain.append(fill(300, 0x30))
    return RecSigner(chain^, fill(64, 0x55), scheme, List[UInt8]())


def server(suite: Int, groups: List[Int], alpn: List[String] = List[String]()) raises -> Server13[RecSigner]:
    var cfg = ServerConfig(fill(32, 0x77), fill(32, 0x21), fill(32, 0x12))
    cfg.suites = [suite]
    cfg.groups = groups.copy()
    cfg.alpn = alpn.copy()
    return Server13[RecSigner](cfg^, signer())


def client(h: Hello, host: String = "example.com") raises -> Client13[RecVerifier]:
    var chain = List[List[UInt8]]()
    chain.append(fill(300, 0x30))
    return Client13[RecVerifier](h, host, fill(32, 0x42), fill(32, 0x13), RecVerifier(chain^, fill(64, 0x55), 0x0403, List[UInt8](), host))


def hello(alpn: List[String] = List[String](), sid: Int = 0, suites: List[Int] = List[Int]()) raises -> Hello:
    var h = default_hello("example.com", fill(32, 0x99), fill(sid, 0x31), x25519_base(fill(32, 0x42)), alpn)
    if len(suites) > 0:
        h.suites = suites.copy()
    return h^


struct Res(Movable):
    var cdone: Bool
    var sdone: Bool
    var cerr: String
    var serr: String
    var cdata: List[UInt8]
    var sdata: List[UInt8]
    var cev: List[Int]
    var sev: List[Int]

    def __init__(out self):
        self.cdone = False
        self.sdone = False
        self.cerr = String()
        self.serr = String()
        self.cdata = List[UInt8]()
        self.sdata = List[UInt8]()
        self.cev = List[Int]()
        self.sev = List[Int]()


def take(mut r: Res, o: Out, client_side: Bool):
    if client_side:
        r.cdone = r.cdone or o.has(EV_DONE)
        r.cdata.extend(Span(o.data))
        r.cev.extend(Span(o.events))
        if o.error.byte_length() > 0:
            r.cerr = o.error
    else:
        r.sdone = r.sdone or o.has(EV_DONE)
        r.sdata.extend(Span(o.data))
        r.sev.extend(Span(o.events))
        if o.error.byte_length() > 0:
            r.serr = o.error


def pump[V: Verifier, S: Signer](mut c: Client13[V], mut s: Server13[S], var wire: List[UInt8], chunk: Int = 0) raises -> Res:
    """Carry bytes both ways until neither side has anything to say; chunk > 0 feeds that many bytes at a time."""
    var r = Res()
    var to_server = True
    for _ in range(40):
        var o = Out()
        if chunk == 0:
            o = s.feed(Span(wire)) if to_server else c.feed(Span(wire))
        else:
            var i = 0
            while i < len(wire):
                var piece = List[UInt8](Span(wire)[i : min(i + chunk, len(wire))])
                var p = s.feed(Span(piece)) if to_server else c.feed(Span(piece))
                o.send.extend(Span(p.send))
                o.data.extend(Span(p.data))
                o.events.extend(Span(p.events))
                if p.error.byte_length() > 0:
                    o.error = p.error
                i += chunk
        take(r, o, not to_server)
        wire = o.send.copy()
        to_server = not to_server
        if len(wire) == 0 and len(o.events) == 0 and not to_server:
            break
        if len(wire) == 0:
            # this side had nothing to send; the other side may still hold a reply, ask it with no input
            var q = Out()
            q = s.feed(Span(wire)) if to_server else c.feed(Span(wire))
            take(r, q, not to_server)
            if len(q.send) == 0:
                break
            wire = q.send.copy()
            to_server = not to_server
    return r^


def direct_shares(mut t: T) raises:
    """The client sends the share of secp384r1 or x448 at once (no HRR): both sides derive the same keys and finish."""
    for g in range(2):
        var group = G_P384 if g == 0 else G_X448
        var h = hello()
        h.exts[find(h.exts, X_KEYSHARE)] = x_keyshares([(group, p384_public(fill(48, 0x24)) if g == 0 else x448_base(fill(56, 0x25)))])
        var c = client(h)
        c.q_priv = fill(48, 0x24)
        c.y_priv = fill(56, 0x25)
        var s = server(0x1301, [G_X25519, G_P256, G_P384, G_X448])
        var r = pump(c, s, c.start())
        var tag = ("secp384r1" if g == 0 else "x448") + " direct share: "
        t.ok(tag + "both sides done (" + r.cerr + r.serr + ")", r.cdone and r.sdone and r.cerr == "" and r.serr == "" and c.group == group and s.group == group)
        var wire = c.write(pattern(100, 4))
        t.ok(tag + "data flows", s.feed(Span(wire)).data == pattern(100, 4))
    # a share of the right group but the wrong length, or a point not on the curve, is illegal_parameter
    for g in range(3):
        var group = [G_P384, G_X448, G_P384][g]
        var bad = p384_public(fill(48, 0x24)) if g == 2 else fill(10, 0x01)
        if g == 2:
            bad[len(bad) - 1] ^= 1
        var h = hello()
        h.exts[find(h.exts, X_KEYSHARE)] = x_keyshares([(group, bad^)])
        var c = client(h)
        var s = server(0x1301, [G_X25519, G_P256, G_P384, G_X448])
        var r = pump(c, s, c.start())
        t.ok("bad " + String(group) + " share " + String(g) + " is refused: " + r.serr, "illegal_parameter" in r.serr and not r.sdone)


def matrix(mut t: T) raises:
    var names = List[String]()
    names.append("TLS_AES_128_GCM_SHA256")
    names.append("TLS_AES_256_GCM_SHA384")
    names.append("TLS_CHACHA20_POLY1305_SHA256")
    var suites = [0x1301, 0x1302, 0x1303]
    for si in range(3):
        for hrr in range(4):
            var groups: List[Int] = [G_X25519, G_P256, G_P384, G_X448]
            var want = G_X25519
            var gname = " x25519"
            if hrr > 0:
                want = [G_P256, G_P384, G_X448][hrr - 1]
                groups = [want]
                gname = [" via HRR to secp256r1", " via HRR to secp384r1", " via HRR to x448"][hrr - 1]
            var tag = names[si] + gname + ": "
            var s = server(suites[si], groups)
            var h = hello()
            var c = client(h)
            var r = pump(c, s, c.start())
            t.ok(tag + "both sides done, no error (" + r.cerr + r.serr + ")", r.cdone and r.sdone and r.cerr == "" and r.serr == "")
            t.ok(tag + "suite and group agree", c.c.suite == suites[si] and s.c.suite == suites[si] and c.group == want and s.group == c.group)
            t.ok(tag + "SNI reached the server", s.sni == "example.com")
            # data both ways, 50000 bytes = 4 records
            var up = pattern(50000, 1)
            var wire = c.write(up)
            var so = s.feed(Span(wire))
            t.ok(tag + "50000 bytes client to server", so.data == up and len(wire) > 50000 + 3 * 22)
            var down = pattern(777, 5)
            var co = c.feed(Span(s.write(down)))
            t.ok(tag + "777 bytes server to client", co.data == down)
            # KeyUpdate both ways: requested by the client, then by the server
            var before = c.c.tx.seq
            var ku = c.key_update()
            var so2 = s.feed(Span(ku))
            t.ok(tag + "server saw KeyUpdate and answered", so2.has(EV_KEYUPDATE) and len(so2.send) > 0 and c.c.tx.seq == 0 and before > 0)
            var co2 = c.feed(Span(so2.send))
            t.ok(tag + "client saw the answer", co2.has(EV_KEYUPDATE) and len(co2.send) == 0)
            var d1 = c.feed(Span(s.write(pattern(300, 9))))
            var d2 = s.feed(Span(c.write(pattern(301, 8))))
            t.ok(tag + "data flows under the new keys", d1.data == pattern(300, 9) and d2.data == pattern(301, 8))
            var ku2 = s.key_update()
            var co3 = c.feed(Span(ku2))
            var so3 = s.feed(Span(co3.send))
            t.ok(tag + "server-initiated KeyUpdate round trip", co3.has(EV_KEYUPDATE) and so3.has(EV_KEYUPDATE))
            var d3 = s.feed(Span(c.write(pattern(10, 3))))
            t.ok(tag + "data after the second update", d3.data == pattern(10, 3))
            # close_notify
            var cl = c.close()
            var scl = s.feed(Span(cl))
            var ccl = c.feed(Span(scl.send))
            t.ok(tag + "close_notify both ways, keys wiped", scl.has(EV_CLOSE) and ccl.has(EV_CLOSE) and s.c.state == S_CLOSED and c.c.state == S_CLOSED and not s.c.tx.on)


def options(mut t: T) raises:
    # ALPN, byte-wise feeding
    var s = server(0x1301, [G_X25519], [String("http/1.1")])
    var h = hello([String("h2"), String("http/1.1")])
    var c = client(h)
    var r = pump(c, s, c.start(), 1)
    t.ok("byte-wise fed handshake completes; ALPN http/1.1 chosen on both sides", r.cdone and r.sdone and c.alpn == "http/1.1" and s.alpn == "http/1.1")
    var s2 = server(0x1301, [G_X25519], [String("spdy")])
    var h2 = hello([String("h2")])
    var c2 = client(h2)
    var r2 = pump(c2, s2, c2.start())
    t.ok("no common ALPN: server fails with no_application_protocol, client sees the alert", r2.serr.startswith("tls: no_application_protocol") and r2.cerr == "tls: peer_alert: no_application_protocol")
    # record_size_limit: client offers 200, server 100: the server flight is split in records of at most 199 bytes
    var s3 = server(0x1301, [G_X25519])
    s3.cfg.rsl = 100
    var h3 = hello()
    h3.exts.append(x_rsl(200))
    var c3 = client(h3)
    var first = c3.start()
    var so = s3.feed(Span(first))
    var biggest = 0
    var i = 0
    while i + 5 <= len(so.send):
        var n = (Int(so.send[i + 3]) << 8) | Int(so.send[i + 4])
        if so.send[i] == 23 and n > biggest:
            biggest = n
        i += 5 + n
    t.ok("server records stay within the client's record_size_limit (largest " + String(biggest) + " <= 215)", biggest > 0 and biggest <= 199 + 1 + 16)
    var co = c3.feed(Span(so.send))
    t.ok("client reassembles handshake messages split over records", co.has(EV_DONE) and co.error == "")
    var r3 = pump(c3, s3, co.send.copy())
    t.ok("client limit follows the server's 100: sends records of at most 99 bytes", r3.sdone and c3.c.tx.limit == 99 and s3.c.tx.limit == 199 and s3.c.rx_limit == 99)
    var w = c3.write(pattern(1000, 2))
    t.ok("1000 bytes arrive over small records", s3.feed(Span(w)).data == pattern(1000, 2) and len(w) >= 11 * (5 + 1 + 16))
    # automatic KeyUpdate at the key limit
    var s4 = server(0x1303, [G_X25519])
    var h4 = hello()
    var c4 = client(h4)
    var r4 = pump(c4, s4, c4.start())
    c4.c.key_limit = 3
    var got = List[UInt8]()
    var updates = 0
    var rd = r4.cdone
    for k in range(10):
        var so4 = s4.feed(Span(c4.write(pattern(20, k))))
        got.extend(Span(so4.data))
        if so4.has(EV_KEYUPDATE):
            updates += 1
        var back = c4.feed(Span(so4.send))
        if back.error.byte_length() > 0:
            rd = False
    var expect = List[UInt8]()
    for k in range(10):
        expect.extend(Span(pattern(20, k)))
    t.ok("10 writes with key_limit 3: all data arrives, the client updated its key " + String(updates) + " times", rd and got == expect and updates >= 3)
    # NewSessionTicket cap: 8 kept
    var s5 = server(0x1301, [G_X25519])
    var h5 = hello()
    var c5 = client(h5)
    _ = pump(c5, s5, c5.start())
    var nst = Ticket(60, 7, fill(2, 1), fill(20, 2), List[Ext]()).encode()
    var tw = List[UInt8]()
    for _ in range(10):
        seal_all(s5.c.tx, HS, nst, tw)
    _ = c5.feed(Span(tw))
    t.ok("10 NewSessionTickets: 8 kept", len(c5.c.tickets) == 8)


def sealed(mut c: Cipher, typ: Int, data: List[UInt8]) raises -> List[UInt8]:
    var o = List[UInt8]()
    seal_all(c, typ, data, o)
    return o^


def alerts(mut t: T) raises:
    # server side
    var h1 = hello()
    h1.exts[find(h1.exts, X_VERSIONS)] = x_versions_client([0x0303])
    var s1 = server(0x1301, [G_X25519])
    var c1 = client(h1)
    var o1 = s1.feed(Span(c1.start()))
    t.ok("TLS 1.2-only ClientHello: protocol_version (70)", o1.error.startswith("tls: protocol_version") and len(o1.send) == 7 and o1.send[6] == 70)
    var s2 = server(0x1302, [G_X25519])
    var h2 = hello(suites=[0x1301])
    var c2 = client(h2)
    var o2 = s2.feed(Span(c2.start()))
    t.ok("no common cipher suite: handshake_failure (40)", o2.error.startswith("tls: handshake_failure") and o2.send[6] == 40)
    var s2b = server(0x1301, [G_X25519])
    var h2b = hello()
    _ = h2b.exts.pop(find(h2b.exts, X_SIGALGS))
    var plain = Cipher()
    var o2b = s2b.feed(Span(sealed(plain, HS, h2b.encode())))
    t.ok("ClientHello without signature_algorithms: missing_extension (109)", o2b.error.startswith("tls: missing_extension") and o2b.send[6] == 109)
    # CH2 checks
    var base = server(0x1301, [G_P256])
    base.cfg.cookie = fill(10, 0xAB)
    var h3 = hello()
    var c3 = client(h3)
    var so = base.feed(Span(c3.start()))
    var ch2 = c3.feed(Span(so.send))
    t.ok("HRR then ClientHello 2 accepted with cookie", len(ch2.send) > 0 and ch2.error == "")
    var good = ch2.send.copy()
    var s3 = server(0x1301, [G_P256])
    s3.cfg.cookie = fill(10, 0xAB)
    var h3b = hello()
    var c3b = client(h3b)
    _ = s3.feed(Span(c3b.start()))
    var badcookie = good.copy()
    badcookie[len(badcookie) - 3] ^= 1  # the cookie is the last extension of this ClientHello 2
    var o3 = s3.feed(Span(badcookie))
    t.ok("changed cookie in ClientHello 2: illegal_parameter (" + o3.error + ")", o3.error.startswith("tls: illegal_parameter"))
    var s3c = server(0x1301, [G_P256])
    s3c.cfg.cookie = fill(10, 0xAB)
    var h3c = hello()
    var c3c = client(h3c)
    _ = s3c.feed(Span(c3c.start()))
    var badrand = good.copy()
    badrand[11] ^= 1  # first random byte: record header 5 + handshake header 4 + version 2
    t.ok("changed random in ClientHello 2: illegal_parameter", s3c.feed(Span(badrand)).error.startswith("tls: illegal_parameter"))
    # message size cap and unknown record type, before any key
    var s4 = server(0x1301, [G_X25519])
    var hdr: List[UInt8] = [22, 3, 1, 0, 4, 1, 1, 0, 1]
    t.ok("handshake message of 65537 bytes: decode_error (50)", s4.feed(Span(hdr)).error.startswith("tls: decode_error"))
    var s4b = server(0x1301, [G_X25519])
    var junk: List[UInt8] = [99, 3, 3, 0, 1, 0]
    t.ok("unknown record type: unexpected_message (10)", s4b.feed(Span(junk)).error.startswith("tls: unexpected_message"))
    var s4c = server(0x1301, [G_X25519])
    var oversize: List[UInt8] = [23, 3, 3, 0x41, 0x01]
    t.ok("record header of 2^14+257 bytes: record_overflow (22)", s4c.feed(Span(oversize)).error.startswith("tls: record_overflow"))
    # client side: certificate refused, wrong session id echo
    var s5 = server(0x1301, [G_X25519])
    var h5 = hello()
    var c5 = Client13[Refuse](h5, "example.com", fill(32, 0x42), fill(32, 0x13), Refuse())
    var r5 = pump(c5, s5, c5.start())
    t.ok("verifier refuses: client fails with bad_certificate, server sees peer alert", r5.cerr.startswith("tls: bad_certificate") and r5.serr == "tls: peer_alert: bad_certificate" and not r5.cdone)
    var s6 = server(0x1301, [G_X25519])
    var h6 = hello(sid=32)
    var c6 = client(h6)
    var sh = s6.feed(Span(c6.start())).send.copy()
    sh[44] ^= 1  # session id echo, record header 5 + handshake header 4 + version 2 + random 32 + length 1
    t.ok("wrong legacy_session_id_echo: illegal_parameter", c6.feed(Span(sh)).error.startswith("tls: illegal_parameter"))
    # post-handshake rejections
    var s7 = server(0x1301, [G_X25519])
    var h7 = hello()
    var c7 = client(h7)
    var r7 = pump(c7, s7, c7.start())
    var plain_alert: List[UInt8] = [21, 3, 3, 0, 2, 2, 40]
    t.ok("plaintext alert after the handshake: unexpected_message", c7.feed(Span(plain_alert)).error.startswith("tls: unexpected_message"))
    var s8 = server(0x1301, [G_X25519])
    var h8 = hello()
    var c8 = client(h8)
    _ = pump(c8, s8, c8.start())
    var ccs: List[UInt8] = [20, 3, 3, 0, 1, 1]
    t.ok("ChangeCipherSpec after the handshake: unexpected_message", c8.feed(Span(ccs)).error.startswith("tls: unexpected_message"))
    var s9 = server(0x1301, [G_X25519])
    var h9 = hello()
    var c9 = client(h9)
    _ = pump(c9, s9, c9.start())
    var ku_bad = sealed(s9.c.tx, HS, hs_msg(H_KU, [UInt8(2)]))
    var o9 = c9.feed(Span(ku_bad))
    t.ok("KeyUpdate value 2: illegal_parameter", o9.error.startswith("tls: illegal_parameter"))
    var s10 = server(0x1301, [G_X25519])
    var h10 = hello()
    var c10 = client(h10)
    _ = pump(c10, s10, c10.start())
    var two = enc_ku(False)
    two.extend(Span(enc_ku(False)))
    var o10 = c10.feed(Span(sealed(s10.c.tx, HS, two)))
    t.ok("KeyUpdate followed by another message in its record: unexpected_message", o10.error.startswith("tls: unexpected_message"))
    var s11 = server(0x1301, [G_X25519])
    var h11 = hello()
    var c11 = client(h11)
    _ = pump(c11, s11, c11.start())
    var fatal: List[UInt8] = [2, 40]
    var o11 = s11.feed(Span(sealed(c11.c.tx, ALERT, fatal)))
    t.ok("peer fatal alert: error names it, no alert is sent back", o11.error == "tls: peer_alert: handshake_failure" and len(o11.send) == 0)
    t.ok("keys are zeroed after a failure", s11.c.state == S_FAILED and not s11.c.rx.on and s11.c.rx_secret[0] == 0 and s11.c.rx_secret[31] == 0)
    var s12 = server(0x1301, [G_X25519])
    var h12 = hello()
    var c12 = client(h12)
    _ = pump(c12, s12, c12.start())
    var cht = Cipher()
    var o12 = s12.feed(Span(sealed(cht, APP, fill(5, 1))))
    t.ok("unprotected 5-byte application_data record after the handshake: bad_record_mac", o12.error.startswith("tls: bad_record_mac"))
    var s13 = server(0x1301, [G_X25519])
    var h13 = hello()
    var c13 = client(h13)
    _ = s13.feed(Span(c13.start()))
    var early = Cipher()
    early.set(0x1301, traffic_key(32, s13.c.chs, 16), traffic_iv(32, s13.c.chs))
    var o13 = s13.feed(Span(sealed(early, APP, fill(5, 1))))
    t.ok("encrypted application data before the client Finished: unexpected_message", o13.error.startswith("tls: unexpected_message"))


def fuzz(mut t: T) raises:
    var seed: UInt64 = 0x452821e638d01377
    var crashed = 0
    var errors = 0
    # random garbage into fresh machines
    for k in range(400):
        seed = seed * 6364136223846793005 + 1442695040888963407
        var n = 1 + Int((seed >> 40) % 200)
        var junk = List[UInt8](length=n, fill=0)
        for i in range(n):
            seed = seed * 6364136223846793005 + 1442695040888963407
            junk[i] = UInt8((seed >> 56) & 0xFF)
        if k % 2 == 0 and n > 5:  # make the record header plausible so the parsers get deeper
            junk[0] = 22
            junk[1] = 3
            junk[2] = 1
            junk[3] = 0
            junk[4] = UInt8(n - 5)
        var s = server(0x1301, [G_X25519])
        errors += 1 if s.feed(Span(junk)).error.byte_length() > 0 else 0
        var h = hello()
        var c = client(h)
        _ = c.start()
        errors += 1 if c.feed(Span(junk)).error.byte_length() > 0 else 0
    t.ok("400 garbage inputs into fresh servers and clients: no crash (" + String(errors) + " ended in an alert)", errors > 0)
    # bit flips in a real ClientHello and a real server flight
    var h0 = hello(sid=32)
    var c0 = client(h0)
    var ch = c0.start()
    var s0 = server(0x1301, [G_X25519])
    var flight = s0.feed(Span(ch)).send.copy()
    var ch_err = 0
    var fl_err = 0
    for k in range(300):
        seed = seed * 6364136223846793005 + 1442695040888963407
        var m = ch.copy()
        m[Int((seed >> 33) % UInt64(len(m)))] ^= UInt8(1 << Int((seed >> 20) % 8))
        var s = server(0x1301, [G_X25519])
        ch_err += 1 if s.feed(Span(m)).error.byte_length() > 0 else 0
        var f = flight.copy()
        f[Int((seed >> 13) % UInt64(len(f)))] ^= UInt8(1 << Int((seed >> 27) % 8))
        var h = hello(sid=32)
        var c = client(h)
        _ = c.start()
        fl_err += 1 if c.feed(Span(f)).error.byte_length() > 0 else 0
    t.ok("300 bit flips in a ClientHello and 300 in a server flight: no crash (" + String(ch_err) + " and " + String(fl_err) + " rejected)", fl_err > 250)
    # every truncation of the flight waits for more bytes without an error
    var waits = 0
    for n in range(len(flight)):
        var h = hello(sid=32)
        var c = client(h)
        _ = c.start()
        var o = c.feed(Span(List[UInt8](Span(flight)[0:n])))
        if o.error.byte_length() == 0:
            waits += 1
    t.ok("every proper prefix of a server flight is accepted as 'need more bytes' (" + String(waits) + "/" + String(len(flight)) + ")", waits == len(flight))


def main() raises:
    var t = T("conn")
    matrix(t)
    direct_shares(t)
    options(t)
    alerts(t)
    fuzz(t)
    t.done()
