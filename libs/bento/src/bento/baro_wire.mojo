"""The mojo-baro engine's line protocol (mojo-baro `serve/PROTOCOL.md`): request lines out, event lines in."""
from json import parse, Json

comptime LOG = 0  # not a protocol line: engine diagnostics
comptime READY = 1
comptime TOK = 2
comptime DONE = 3
comptime ERROR = 4
comptime OTHER = 5  # embed / hidden / logits_topk lines: valid, not used here


@fieldwise_init
struct GenReq(Copyable, Movable):
    """One generation: prompt token ids in, `n` tokens at most out. `stop` is a list of token-id sequences."""

    var prompt: List[Int]
    var n: Int
    var stop: List[List[Int]]
    var spec: Int  # -1: the engine's default, 0: off, 1: on


@fieldwise_init
struct GenResp(Copyable, Movable):
    var tokens: List[Int]
    var finish: String  # "length" | "stop" | "cancelled"
    var prefill_s: Float64
    var decode_s: Float64
    var error: String  # set instead of tokens when the engine rejected the request or died

    def tok_s(self) -> Float64:
        return Float64(len(self.tokens) - 1) / self.decode_s if len(self.tokens) > 1 and self.decode_s > 0.0 else 0.0


def request_line(id: Int, req: GenReq) -> String:
    var s = String('{"id":') + String(id) + ',"prompt":['
    for i in range(len(req.prompt)):
        s += ("," if i > 0 else "") + String(req.prompt[i])
    s += '],"n":' + String(req.n)
    if req.spec >= 0:
        s += ',"spec":' + ("true" if req.spec == 1 else "false")
    if len(req.stop) > 0:
        s += ',"stop":['
        for i in range(len(req.stop)):
            s += "," if i > 0 else ""
            s += "["
            for j in range(len(req.stop[i])):
                s += ("," if j > 0 else "") + String(req.stop[i][j])
            s += "]"
        s += "]"
    return s + "}\n"


def cancel_line(id: Int) -> String:
    return '{"cancel":' + String(id) + "}\n"


struct Event(Copyable, Movable):
    var kind: Int
    var id: Int
    var tok: Int
    var n: Int
    var finish: String
    var error: String
    var prefill_s: Float64
    var decode_s: Float64
    var tmax: Int

    def __init__(out self, kind: Int):
        self.kind = kind
        self.id = 0
        self.tok = 0
        self.n = 0
        self.finish = String()
        self.error = String()
        self.prefill_s = 0.0
        self.decode_s = 0.0
        self.tmax = 0


def parse_event(line: String) -> Event:
    """Classify one engine stdout line. Anything that is not a JSON object with a known key is a log line."""
    if not line.startswith("{"):
        return Event(LOG)
    var j: Json
    try:
        j = parse(line)
    except:
        return Event(LOG)
    if j.has("ready"):
        var e = Event(READY)
        e.tmax = j.get("tmax").int()
        return e^
    if not j.has("id"):
        return Event(LOG)
    var id = j.get("id").int()
    if j.has("tok"):
        var e = Event(TOK)
        e.id = id
        e.tok = j.get("tok").int()
        return e^
    if j.has("done"):
        var e = Event(DONE)
        e.id = id
        e.n = j.get("n").int()
        e.finish = j.text("finish")
        e.prefill_s = j.get("prefill_s").num()
        e.decode_s = j.get("decode_s").num()
        return e^
    if j.has("error"):
        var e = Event(ERROR)
        e.id = id
        e.error = j.text("error")
        return e^
    if j.has("embed") or j.has("hidden") or j.has("logits_topk"):
        var e = Event(OTHER)
        e.id = id
        return e^
    return Event(LOG)
