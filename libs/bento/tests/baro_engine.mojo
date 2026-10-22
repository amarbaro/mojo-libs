"""bento.baro against tests/fake_engine (the engine's line protocol, no GPU): process start and shutdown, id routing,
stop sequences, a rejected request inside a batch, an engine that dies, and a Batcher in front of it under 16 threads.
usage: baro_engine FAKE_ENGINE_BINARY RUN_DIR"""
from std.ffi import external_call
from std.memory import alloc
from std.sys import argv
from std.testing import assert_equal, assert_true
from posix import killpg
from bento.baro import Engine, Call, run_calls
from bento.baro_wire import GenReq, GenResp, request_line, parse_event, LOG, READY, TOK, DONE, ERROR, OTHER
from bento.batch import Batcher

comptime WORKERS = 16
comptime PER_WORKER = 10


def expect(prompt: List[Int], n: Int) -> List[Int]:
    var s = 0
    for t in prompt:
        s += t
    var out = List[Int]()
    for i in range(n):
        out.append((s * 31 + i * 17 + 7) % 50021)
    return out^


def req(a: Int, n: Int) -> GenReq:
    return GenReq([a, a + 1, a + 2], n, [], -1)


def check(r: GenResp, prompt: List[Int], n: Int) raises:
    assert_equal(r.error, "")
    assert_equal(r.finish, "length")
    var want = expect(prompt, n)
    assert_equal(len(r.tokens), n)
    for i in range(n):
        assert_equal(r.tokens[i], want[i])


@fieldwise_init
struct Ctx(Movable):
    var b: Int  # address of the shared Batcher
    var engine: Int
    var id: Int
    var bad: Int
    var errs: Int


def worker(arg: Int) abi("C") -> Int:
    var c = MutPointer[Ctx, MutUntrackedOrigin](unsafe_from_address=arg)
    for k in range(PER_WORKER):
        var a = 1000 + c[].id * 100 + k
        try:
            var r = MutPointer[Batcher[Call, GenResp], MutUntrackedOrigin](unsafe_from_address=c[].b)[].submit(
                Call(c[].engine, req(a, 3 + k % 4))
            )
            var want = expect([a, a + 1, a + 2], 3 + k % 4)
            if len(r.tokens) != len(want):
                c[].bad += 1
            else:
                for i in range(len(want)):
                    if r.tokens[i] != want[i]:
                        c[].bad += 1
        except:
            c[].errs += 1
    return 0


def main() raises:
    var a = argv()
    # wire layer
    assert_equal(request_line(7, GenReq([1, 2], 5, [[9], [8, 7]], 0)), '{"id":7,"prompt":[1,2],"n":5,"spec":false,"stop":[[9],[8,7]]}\n')
    assert_equal(request_line(1, GenReq([3], 1, [], -1)), '{"id":1,"prompt":[3],"n":1}\n')
    assert_equal(parse_event("loading pack").kind, LOG)
    assert_equal(parse_event("{not json").kind, LOG)
    assert_equal(parse_event('{"ready":true,"tmax":128,"mrows":8}').tmax, 128)
    assert_equal(parse_event('{"id":4,"tok":99}').tok, 99)
    var d = parse_event('{"id":4,"done":true,"n":3,"prefill_s":0.5,"decode_s":1.5,"tok_s":1.3,"finish":"stop"}')
    assert_equal(d.kind, DONE)
    assert_equal(d.finish, "stop")
    assert_equal(parse_event('{"id":4,"error":"bad"}').error, "bad")
    assert_equal(parse_event('{"id":4,"hidden":[1.0]}').kind, OTHER)

    var e = Engine(String(a[1]), "fake", String(a[2]))
    assert_equal(e.tmax(), 4096)
    # one request, then a burst of eight: each answer is its own request's
    check(e.generate(req(10, 6)), [10, 11, 12], 6)
    var reqs = List[GenReq]()
    for i in range(8):
        reqs.append(req(100 + i, 2 + i))
    var rs = e.generate_batch(reqs)
    assert_equal(len(rs), 8)
    for i in range(8):
        check(rs[i], [100 + i, 101 + i, 102 + i], 2 + i)
    # a stop sequence ends a request early; a rejected one fails alone
    var stop_at = expect([5, 6, 7], 4)
    var mixed = List[GenReq]()
    mixed.append(GenReq([5, 6, 7], 10, [[stop_at[2], stop_at[3]]], -1))
    mixed.append(GenReq([1], 0, [], -1))
    mixed.append(req(20, 3))
    var ms = e.generate_batch(mixed)
    assert_equal(ms[0].finish, "stop")
    assert_equal(len(ms[0].tokens), 4)
    assert_true(ms[1].error.byte_length() > 0, "n=0 must be rejected")
    assert_equal(len(ms[1].tokens), 0)
    check(ms[2], [20, 21, 22], 3)

    # a Batcher in front: 16 threads, each answer its own, and batches really form
    var b = Batcher[Call, GenResp](run_calls, 10_000, 8)
    var bp = Int(Pointer(to=b))
    var ctxs = alloc[Ctx](WORKERS)
    var tids = alloc[UInt64](WORKERS)
    for i in range(WORKERS):
        ctxs.unsafe_offset(i).unsafe_write(Ctx(bp, e.address(), i, 0, 0))
        assert_equal(external_call["pthread_create", Int32](tids.unsafe_offset(i), Int(0), worker, Int(ctxs.unsafe_offset(i))), 0)
    var bad = 0
    var errs = 0
    for i in range(WORKERS):
        _ = external_call["pthread_join", Int32](tids.unsafe_offset(i)[], Int(0))
        bad += ctxs.unsafe_offset(i)[].bad
        errs += ctxs.unsafe_offset(i)[].errs
    assert_equal(bad, 0, "wrong tokens through the batcher")
    assert_equal(errs, 0, "errors through the batcher")
    var st = b.stats()
    assert_equal(st[1], WORKERS * PER_WORKER)
    assert_true(st[0] < WORKERS * PER_WORKER, "no batching")
    print("batcher: ", WORKERS * PER_WORKER, "requests in", st[0], "engine bursts")
    b.close()

    # the engine dies mid-request: the waiter gets an error, not a hang
    var long = e.submit(req(1, 400))
    _ = external_call["usleep", Int32](Int32(50_000))
    _ = killpg(e.core[].pid, 9)
    var dead = e.wait(long)
    assert_equal(dead.error, "baro: engine exited")
    var refused = False
    try:
        _ = e.generate(req(1, 1))
    except:
        refused = True
    assert_true(refused, "a dead engine must refuse new requests")
    e.close()

    # clean shutdown: closing stdin ends a live engine
    var e2 = Engine(String(a[1]), "fake", String(a[2]))
    check(e2.generate(req(3, 2)), [3, 4, 5], 2)
    e2.close()
    print("PASS baro-engine")
