"""The B2 test service: tools/oracle_service.py in Mojo. The gate sends the same requests to both."""
from json import Json
from posix import block_signals
from bento.endpoint import Service, Endpoint, Field, T_STR, T_INT, T_FLOAT, T_BOOL, T_LIST, http_error
from bento.http import Limits
from bento.server import Server


struct Echo(Endpoint):
    comptime name = "echo"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("text", T_STR)]

    def call(self, args: Json) raises -> Json:
        return args.get("text")


struct Add(Endpoint):
    comptime name = "add"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("a", T_INT), Field("b", T_INT)]

    def call(self, args: Json) raises -> Json:
        return Json.of(args.get("a").int() + args.get("b").int())


struct Stats(Endpoint):
    comptime name = "stats"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("values", T_LIST, T_FLOAT)]

    def call(self, args: Json) raises -> Json:
        var v = args.get("values")
        var sum = 0.0
        for i in range(v.len()):
            sum += v.at(i).num()
        var out = Json.object()
        out.set("count", Json.of(v.len()))
        out.set("sum", Json.of(sum) if v.len() > 0 else Json.of(0))  # Python: sum([]) is the int 0
        out.set("mean", Json.of(sum / Float64(v.len())) if v.len() > 0 else Json())
        return out^


struct Greet(Endpoint):
    comptime name = "greet"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("name", T_STR), Field("excited", T_BOOL, Json.of(False))]

    def call(self, args: Json) raises -> Json:
        return Json.of("Hello, " + args.get("name").str() + ("!" if args.get("excited").truthy() else "."))


struct Boom(Endpoint):
    comptime name = "boom"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return []

    def call(self, args: Json) raises -> Json:
        raise Error("kaboom")


struct Refuse(Endpoint):
    comptime name = "refuse"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("why", T_STR)]

    def call(self, args: Json) raises -> Json:
        raise http_error(400, args.get("why").str())


struct Tag(Endpoint):
    comptime name = "tag"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("text", T_STR), Field("n", T_INT, Json.of(1))]

    def call(self, args: Json) raises -> Json:
        var t = args.get("text").str()
        var rep = Json.array()
        for _ in range(args.get("n").int()):
            rep.push(Json.of(t))
        var out = Json.object()
        out.set("text", Json.of(t))
        out.set("upper", Json.of(t.upper()))
        out.set("repeat", rep)
        out.set("ok", Json.of(True))
        out.set("none", Json())
        return out^


struct Scale(Endpoint):
    comptime name = "scale"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("values", T_LIST, T_INT), Field("k", T_FLOAT)]

    def call(self, args: Json) raises -> Json:
        var v = args.get("values")
        var out = Json.array()
        for i in range(v.len()):
            out.push(Json.of(Float64(v.at(i).int()) * args.get("k").num()))
        return out^


struct Deny(Endpoint):
    comptime name = "deny"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return []

    def call(self, args: Json) raises -> Json:
        raise http_error(403, "no")


struct Missing(Endpoint):
    comptime name = "missing"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("what", T_STR)]

    def call(self, args: Json) raises -> Json:
        raise http_error(404, args.get("what").str())


struct Unavailable(Endpoint):
    comptime name = "unavailable"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return []

    def call(self, args: Json) raises -> Json:
        raise http_error(503, "later")


def main() raises:
    block_signals([2, 15])
    var port = 0
    var args = List[String]()
    from std.sys import argv

    var a = argv()
    if len(a) > 1:
        port = Int(a[1])
    var srv = Server(Service(Echo(), Add(), Stats(), Greet(), Boom(), Refuse(), Tag(), Scale(), Deny(), Missing(), Unavailable()), "127.0.0.1", port)
    print("LISTEN", srv.port(), flush=True)
    srv.serve(4, True)
