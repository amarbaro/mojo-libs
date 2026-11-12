# mojo-tls lane 4: TLS 1.3 server state machine, sans-IO. Server13(config, signer): feed(bytes) returns an Out.
# One instance serves one connection. Randomness (ServerHello random, ephemeral private keys) comes from the config.
from tls.tls13.client import kex_public, kex_shared
from tls.tls13.conn import *
from tls.tls13.keysched import KeySchedule, finished_mac, cv_content
from tls.tls13.messages import *
from tls.tls13.record import seal_all, HS, MAX_PLAIN
from tls.tls13.verify import Signer
from tls.tls13.wire import bad, ct_equal, wipe


struct ServerConfig(Copyable, Movable):
    var suites: List[Int]  # preference order
    var groups: List[Int]  # preference order
    var alpn: List[String]  # protocols we speak, preference order; empty: ALPN is ignored
    var random: List[UInt8]  # ServerHello.random
    var x_priv: List[UInt8]
    var p_priv: List[UInt8]
    var cookie: List[UInt8]  # sent in a HelloRetryRequest when not empty, must come back unchanged
    var ee_exts: List[Ext]  # extra EncryptedExtensions, sent first
    var rsl: Int  # our record_size_limit, offered when the client offered one; 0 = none

    def __init__(out self, random: List[UInt8], x_priv: List[UInt8], p_priv: List[UInt8]):
        self.suites = [0x1301, 0x1303, 0x1302]
        self.groups = [G_X25519, G_P256]
        self.alpn = List[String]()
        self.random = random.copy()
        self.x_priv = x_priv.copy()
        self.p_priv = p_priv.copy()
        self.cookie = List[UInt8]()
        self.ee_exts = List[Ext]()
        self.rsl = 0


struct Server13[S: Signer](Movable):
    var c: Conn
    var sg: Self.S
    var cfg: ServerConfig
    var ch1: Hello  # the first ClientHello, kept while a HelloRetryRequest is outstanding
    var hrr_group: Int
    var th_sf: List[UInt8]
    var cap: List[UInt8]
    var sni: String  # server_name the client sent, empty if none
    var alpn: String  # protocol selected, empty if none
    var group: Int

    def __init__(out self, var cfg: ServerConfig, var sg: Self.S):
        self.c = Conn(False)
        self.c.state = S_WAIT_CH
        self.sg = sg^
        self.cfg = cfg^
        self.ch1 = Hello(False, List[UInt8](), List[UInt8](), List[Int](), List[Ext]())
        self.hrr_group = 0
        self.th_sf = List[UInt8]()
        self.cap = List[UInt8]()
        self.sni = String()
        self.alpn = String()
        self.group = 0

    def feed(mut self, data: Span[UInt8, _]) -> Out:
        var out = Out()
        if self.c.state >= S_CLOSED:
            return out^
        try:
            self.c.rd.push(data)
            var m = List[UInt8]()
            while self.c.state < S_CLOSED and self.c.step(out):
                while self.c.state < S_CLOSED and self.c.take_msg(m):
                    self.on_msg(out, m)
        except e:
            self.c.fail(e, out)
        return out^

    def write(mut self, data: List[UInt8]) raises -> List[UInt8]:
        return self.c.send_app(data)

    def close(mut self) -> List[UInt8]:
        return self.c.close()

    def key_update(mut self) raises -> List[UInt8]:
        var o = List[UInt8]()
        self.c.key_update(True, o)
        return o^

    def on_msg(mut self, mut out: Out, m: List[UInt8]) raises:
        var s = self.c.state
        if s == S_OPEN:
            self.c.post(out, m)
        elif s == S_WAIT_CH or s == S_WAIT_CH2:
            self.on_ch(out, m, s == S_WAIT_CH2)
        else:
            self.on_fin(out, m)

    def check_ch2(self, ch: Hello) raises:
        """RFC 8446 4.1.2: the second ClientHello equals the first except key_share, cookie and padding."""
        var a = self.ch1.copy()
        if ch.random != a.random or ch.sid != a.sid or ch.suites != a.suites or ch.comp != a.comp:
            raise bad("illegal_parameter", "second ClientHello changed its fixed fields")
        for e in ch.exts:
            if e.t == X_KEYSHARE or e.t == X_PADDING or e.t == X_COOKIE or e.t == X_PSK:
                continue
            var i = find(a.exts, e.t)
            if i < 0 or a.exts[i].d != e.d:
                raise bad("illegal_parameter", "second ClientHello changed an extension")
        for e in a.exts:
            if e.t != X_KEYSHARE and e.t != X_PADDING and e.t != X_PSK and find(ch.exts, e.t) < 0:
                raise bad("illegal_parameter", "second ClientHello dropped an extension")
        var ci = find(ch.exts, X_COOKIE)
        if len(self.cfg.cookie) > 0:
            if ci < 0 or not ct_equal(p_cookie(ch.exts[ci].d), self.cfg.cookie):
                raise bad("illegal_parameter", "cookie missing or changed")
        elif ci >= 0:
            raise bad("illegal_parameter", "cookie we never sent")

    def on_ch(mut self, mut out: Out, m: List[UInt8], second: Bool) raises:
        var ch = parse_hello(m, False)
        if len(ch.comp) != 1 or ch.comp[0] != 0:
            raise bad("illegal_parameter", "compression methods")
        var vi = find(ch.exts, X_VERSIONS)
        if vi < 0 or 0x0304 not in p_versions_client(ch.exts[vi].d):
            raise bad("protocol_version", "client does not offer TLS 1.3")
        var gi = find(ch.exts, X_GROUPS)
        var ki = find(ch.exts, X_KEYSHARE)
        var si = find(ch.exts, X_SIGALGS)
        if gi < 0 or ki < 0 or si < 0:
            raise bad("missing_extension", "supported_groups, key_share and signature_algorithms are required")
        var groups = p_u16s(ch.exts[gi].d)
        var sigs = p_u16s(ch.exts[si].d)
        var shares = p_keyshares(ch.exts[ki].d)
        for s in shares:
            if s[0] not in groups:
                raise bad("illegal_parameter", "key share for a group not listed")
        var suite = 0
        for s in self.cfg.suites:
            if suite == 0 and s in ch.suites:
                suite = s
        if suite == 0:
            raise bad("handshake_failure", "no common cipher suite")
        var scheme = 0
        for s in self.sg.schemes():
            if scheme == 0 and s in sigs:
                scheme = s
        if scheme == 0:
            raise bad("handshake_failure", "no common signature scheme")
        if second:
            self.check_ch2(ch)
        var group = 0
        var kx = List[UInt8]()
        for g in self.cfg.groups:
            for s in shares:
                if group == 0 and s[0] == g:
                    group = g
                    kx = s[1].copy()
        self.c.set_suite(suite)
        if group == 0:
            if second:
                raise bad("illegal_parameter", "second ClientHello has no share for the requested group")
            for g in self.cfg.groups:
                if group == 0 and g in groups:
                    group = g
            if group == 0:
                raise bad("handshake_failure", "no common key exchange group")
            self.c.add(m)
            self.c.transcript = hs_msg(H_MSGHASH, self.c.th())
            var e = List[Ext]()
            e.append(x_keyshare_hrr(group))
            if len(self.cfg.cookie) > 0:
                e.append(x_cookie(self.cfg.cookie))
            e.append(x_versions_server(0x0304))
            var hrr = Hello(True, hrr_random(), ch.sid, [suite], e^).encode()
            self.c.add(hrr)
            seal_all(self.c.tx, HS, hrr, out.send)
            if len(ch.sid) > 0:
                self.c.send_ccs(out.send)
            self.hrr_group = group
            self.ch1 = ch^
            self.c.state = S_WAIT_CH2
            return
        if second and group != self.hrr_group:
            raise bad("illegal_parameter", "second ClientHello key share is not the requested group")
        var sni = find(ch.exts, X_SNI)
        if sni >= 0:
            self.sni = p_sni(ch.exts[sni].d)
        var ai = find(ch.exts, X_ALPN)
        if ai >= 0 and len(self.cfg.alpn) > 0:
            var theirs = p_alpn(ch.exts[ai].d)
            for p in self.cfg.alpn:
                if self.alpn.byte_length() == 0 and p in theirs:
                    self.alpn = p
            if self.alpn.byte_length() == 0:
                raise bad("no_application_protocol", "no common ALPN protocol")
        var ri = find(ch.exts, X_RSL)
        if ri >= 0:
            self.c.tx.limit = min(MAX_PLAIN, p_rsl(ch.exts[ri].d) - 1)
            if self.cfg.rsl > 0:
                self.c.rx_limit = self.cfg.rsl - 1
        self.group = group
        var dhe = kex_shared(group, self.cfg.x_priv, self.cfg.p_priv, kx)
        self.c.add(m)
        var e = List[Ext]()
        e.append(x_keyshare_server(group, kex_public(group, self.cfg.x_priv, self.cfg.p_priv)))
        e.append(x_versions_server(0x0304))
        var shm = Hello(True, self.cfg.random, ch.sid, [suite], e^).encode()
        self.c.add(shm)
        seal_all(self.c.tx, HS, shm, out.send)
        if len(ch.sid) > 0:
            self.c.send_ccs(out.send)
        var th = self.c.th()
        self.c.ks.to_handshake(dhe)
        self.c.chs = self.c.ks.derive("c hs traffic", th)
        self.c.shs = self.c.ks.derive("s hs traffic", th)
        self.c.install_hs()
        # EncryptedExtensions, Certificate, CertificateVerify, Finished in one flight under the server handshake key
        var h = self.c.h
        var ee = self.cfg.ee_exts.copy()
        if self.alpn.byte_length() > 0:
            ee.append(x_alpn([self.alpn]))
        if ri >= 0 and self.cfg.rsl > 0:
            ee.append(x_rsl(self.cfg.rsl))
        var f = List[UInt8]()
        var eem = enc_ee(ee)
        self.c.add(eem)
        f.extend(Span(eem))
        var cm = enc_cert(List[UInt8](), self.sg.chain())
        self.c.add(cm)
        f.extend(Span(cm))
        var cvm = enc_cv(scheme, self.sg.sign(scheme, cv_content(False, self.c.th())))
        self.c.add(cvm)
        f.extend(Span(cvm))
        var fin = enc_fin(finished_mac(h, self.c.shs, self.c.th()))
        self.c.add(fin)
        f.extend(Span(fin))
        seal_all(self.c.tx, HS, f, out.send)
        self.th_sf = self.c.th()
        self.c.ks.to_master()
        self.cap = self.c.ks.derive("c ap traffic", self.th_sf)
        self.c.exp_master = self.c.ks.derive("exp master", self.th_sf)
        self.c.install_tx(self.c.ks.derive("s ap traffic", self.th_sf))
        self.c.state = S_WAIT_FIN

    def on_fin(mut self, mut out: Out, m: List[UInt8]) raises:
        var h = self.c.h
        if not ct_equal(parse_fin(m, h), finished_mac(h, self.c.chs, self.th_sf)):
            raise bad("decrypt_error", "client Finished does not verify")
        self.c.add(m)
        self.c.at_boundary()
        self.c.res_master = self.c.ks.derive("res master", self.c.th())
        self.c.install_rx(self.cap)
        wipe(self.cap)
        wipe(self.c.chs)
        wipe(self.c.shs)
        self.c.state = S_OPEN
        out.events.append(EV_DONE)
