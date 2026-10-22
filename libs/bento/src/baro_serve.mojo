"""baro-serve (mojo-bento): HTTP in front of the mojo-baro engine. See docs/baro.md.

usage: baro_serve --engine BIN --pack DIR [--gguf FILE] [--run-dir DIR] [--port N] [--host H] [--workers N]
                  [--batch N] [--inflight N] [--engine-env KEY=VALUE]...
Prints `LISTEN <port>` once the engine is ready. SIGINT/SIGTERM: stop serving, close the engine's stdin, exit 0.
"""
from std.sys import argv
from posix import block_signals
from bento.baro_service import Baro
from bento.server import Server


def main() raises:
    var a = argv()
    var engine = String()
    var pack = String()
    var gguf = String()
    var run_dir = String(".work/baro-run")
    var host = String("127.0.0.1")
    var port = 0
    var workers = 64
    var batch = 8
    var inflight = 1
    var env = List[String]()
    var i = 1
    while i < len(a):
        var k = String(a[i])
        if i + 1 >= len(a):
            raise Error("FAIL usage: " + k + " needs a value")
        var v = String(a[i + 1])
        if k == "--engine":
            engine = v
        elif k == "--pack":
            pack = v
        elif k == "--gguf":
            gguf = v
        elif k == "--run-dir":
            run_dir = v
        elif k == "--host":
            host = v
        elif k == "--port":
            port = Int(v)
        elif k == "--workers":
            workers = Int(v)
        elif k == "--batch":
            batch = Int(v)
        elif k == "--inflight":
            inflight = Int(v)
        elif k == "--engine-env":
            env.append(v)
        else:
            raise Error("FAIL usage: unknown option " + k)
        i += 2
    if engine.byte_length() == 0 or pack.byte_length() == 0:
        raise Error("FAIL usage: baro_serve --engine BIN --pack DIR [--gguf FILE] [--port N] ...")
    block_signals([2, 15])
    var baro = Baro(engine, pack, run_dir, gguf, batch, inflight, "", env)
    var srv = Server(baro.app(), host, port)
    print("LISTEN", srv.port(), flush=True)
    srv.serve(workers, True)
    baro.close()
