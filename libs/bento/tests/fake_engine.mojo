"""A stand-in for the mojo-baro engine's BARO_SERVE=1 line protocol (serve/PROTOCOL.md), for tests that must not need the GPU.

One request at a time, in arrival order. Token i of a request is (sum(prompt) * 31 + i * 17 + 7) % 50021, so the output
is a pure function of the request. FAKE_TOK_US (default 2000) is the time per token, FAKE_PREFILL_US (default 5000) the
prefill; stdin EOF ends it. Prints one log line per request like the real engine's diagnostics.
"""
from std.ffi import external_call, c_ssize_t
from std.memory import alloc
from std.os import getenv
from json import parse, Json

comptime TMAX = 4096


def sleep_us(us: Int):
    _ = external_call["usleep", Int32](Int32(us))


def env_int(name: String, default: Int) -> Int:
    var v = getenv(name)
    try:
        return Int(v) if v.byte_length() > 0 else default
    except:
        return default


struct Lines:
    """Lines from fd 0. (input() drops the rest of a chunk when the pipe holds several lines.)"""

    var buf: MutPointer[UInt8, MutUntrackedOrigin]
    var acc: List[UInt8]
    var eof: Bool

    def __init__(out self):
        self.buf = alloc[UInt8](65536)
        self.acc = List[UInt8]()
        self.eof = False

    def next(mut self) -> Optional[String]:
        while True:
            for i in range(len(self.acc)):
                if self.acc[i] == 10:
                    var line = String(unsafe_from_utf8=Span(self.acc)[:i])
                    var rest = List[UInt8]()
                    rest.extend(Span(self.acc)[i + 1 :])
                    self.acc = rest^
                    return line^
            if self.eof:
                return None
            var n = Int(external_call["read", c_ssize_t](Int(0), self.buf, 65536))
            if n <= 0:
                self.eof = True
            else:
                self.acc.extend(Span(unsafe_ptr=self.buf, length=n))


def main() raises:
    var lines = Lines()
    var tok_us = env_int("FAKE_TOK_US", 2000)
    var prefill_us = env_int("FAKE_PREFILL_US", 5000)
    print('{"ready":true,"tmax":' + String(TMAX) + ',"mrows":8,"kmax":8,"spec_k":0,"pack":"fake"}', flush=True)
    while True:
        var got = lines.next()
        if not got:
            break
        var line = got.value()
        if not line.startswith("{"):
            continue
        var j: Json
        try:
            j = parse(line)
        except:
            print('{"id":0,"error":"bad json"}', flush=True)
            continue
        if j.has("cancel"):
            continue
        var id = j.get("id").int()
        var prompt = j.get("prompt")
        var n = j.get("n").int()
        if prompt.len() == 0 or n < 1 or prompt.len() + n > TMAX:
            print('{"id":' + String(id) + ',"error":"rejected: empty prompt, n < 1 or len(prompt)+n > tmax"}', flush=True)
            continue
        var s = 0
        for i in range(prompt.len()):
            s += prompt.at(i).int()
        sleep_us(prefill_us)
        var stop = j.get("stop")
        var out = List[Int]()
        var finish = "length"
        for i in range(n):
            sleep_us(tok_us)
            var t = (s * 31 + i * 17 + 7) % 50021
            out.append(t)
            print('{"id":' + String(id) + ',"tok":' + String(t) + "}", flush=True)
            for k in range(stop.len()):
                var seq = stop.at(k)
                var m = seq.len()
                if m > 0 and m <= len(out):
                    var hit = True
                    for q in range(m):
                        if out[len(out) - m + q] != seq.at(q).int():
                            hit = False
                    if hit:
                        finish = "stop"
            if finish == "stop":
                break
        print("fake engine: request " + String(id) + " done", flush=True)
        var dec = Float64(len(out) * tok_us) / 1e6
        print(
            '{"id":' + String(id) + ',"done":true,"n":' + String(len(out)) + ',"prefill_s":' + String(Float64(prefill_us) / 1e6)
            + ',"decode_s":' + String(dec) + ',"tok_s":' + String(Float64(len(out) - 1) / dec if dec > 0.0 else 0.0)
            + ',"finish":"' + finish + '"}',
            flush=True,
        )
