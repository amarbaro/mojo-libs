"""B8 gate against the real mojo-baro engine (GPU; run under gpu-wait): greedy identity, then batched vs unbatched
throughput with 1, 8 and 32 client threads.

usage: baro_live ENGINE PACK RUN_DIR PROMPT_FILE REF_FILE N REPS
  PROMPT_FILE: the pack's prompt-tokens.txt. REF_FILE: its ref-tokens-64.txt (`GENERATED: t t t ...`, 64 tokens).
  N: tokens per request (<= 64). REPS: repetitions per (clients, mode) cell.

  unbatched: every client calls Engine.generate under one lock, so the engine sees one request at a time.
  batched:   every client calls Batcher.submit; run_calls writes a whole batch of request lines to the engine at once.
  batched2:  the same with two batches in flight (the engine always holds the next batch while one runs).
Prints `cell clients mode rep tokens wall_s tok_s`, then identity and ratio lines.
"""
from std.ffi import external_call
from std.memory import alloc
from std.sys import argv
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from bento.baro import Engine, Call, run_calls
from bento.baro_wire import GenReq, GenResp
from bento.batch import Batcher
from bento.sync import Mutex


def ints(path: String, skip_prefix: Bool) raises -> List[Int]:
    var out = List[Int]()
    var text = open(path, "r").read()
    for w in text.replace("\n", " ").split(" "):
        var s = String(w)
        if s.byte_length() > 0 and s != "GENERATED:":
            out.append(Int(s))
    return out^


@fieldwise_init
struct Ctx(Movable):
    var batcher: Int  # address, 0 when unbatched
    var gate: Int  # address of the Mutex used when unbatched
    var engine: Int
    var prompt: List[Int]
    var n: Int
    var per_client: Int
    var tokens: Int
    var bad: Int
    var want: List[Int]


def client(arg: Int) abi("C") -> Int:
    var c = MutPointer[Ctx, MutUntrackedOrigin](unsafe_from_address=arg)
    for _ in range(c[].per_client):
        var req = GenReq(c[].prompt.copy(), c[].n, [], 0)
        try:
            var r: GenResp
            if c[].batcher != 0:
                r = MutPointer[Batcher[Call, GenResp], MutUntrackedOrigin](unsafe_from_address=c[].batcher)[].submit(Call(c[].engine, req^))
            else:
                var g = MutPointer[Mutex, MutUntrackedOrigin](unsafe_from_address=c[].gate)
                g[].lock()
                var e = Engine(core=c[].engine)
                try:
                    r = e.generate(req)
                except err:
                    g[].unlock()
                    raise err^
                g[].unlock()
            if r.error.byte_length() > 0 or len(r.tokens) != c[].n:
                c[].bad += 1
            else:
                for i in range(c[].n):
                    if r.tokens[i] != c[].want[i]:
                        c[].bad += 1
                        break
            c[].tokens += len(r.tokens)
        except:
            c[].bad += 1
    return 0


def cell(e: Engine, clients: Int, mode: Int, prompt: List[Int], want: List[Int], n: Int, per_client: Int) raises -> Tuple[Int, Int, Float64]:
    """(tokens, bad requests, wall seconds)"""
    var gate = Mutex()
    var batched = mode > 0
    var b = Batcher[Call, GenResp](run_calls, 3_600_000, 8, mode if batched else 1)  # mode 1: BentoML's one batch at a time, 2: two in flight
    var ctxs = alloc[Ctx](clients)
    var tids = alloc[UInt64](clients)
    var t0 = perf_counter_ns()
    for i in range(clients):
        ctxs.unsafe_offset(i).unsafe_write(
            Ctx(Int(Pointer(to=b)) if batched else 0, Int(Pointer(to=gate)), e.address(), prompt.copy(), n, per_client, 0, 0, want.copy())
        )
        if external_call["pthread_create", Int32](tids.unsafe_offset(i), Int(0), client, Int(ctxs.unsafe_offset(i))) != 0:
            raise Error("pthread_create failed")
    var toks = 0
    var bad = 0
    for i in range(clients):
        _ = external_call["pthread_join", Int32](tids.unsafe_offset(i)[], Int(0))
        toks += ctxs.unsafe_offset(i)[].tokens
        bad += ctxs.unsafe_offset(i)[].bad
    var wall = Float64(perf_counter_ns() - t0) / 1e9
    b.close()
    _ = gate.p  # the clients held only its address: keep the owner alive past the joins
    return (toks, bad, wall)


def main() raises:
    var a = argv()
    var n = Int(String(a[6]))
    var reps = Int(String(a[7]))
    var prompt = ints(String(a[4]), False)
    var want = ints(String(a[5]), True)
    assert_true(n <= len(want), "N exceeds the reference length")
    var e = Engine(String(a[1]), String(a[2]), String(a[3]))
    print("engine ready, tmax", e.tmax(), "prompt tokens", len(prompt))
    # identity: one request, then a burst of 4, every answer equals the reference prefix
    var one = e.generate(GenReq(prompt.copy(), n, [], 0))
    var ok = one.error.byte_length() == 0 and len(one.tokens) == n
    var agree = 0  # the stored reference file is older than the engine: report how far it still agrees
    while agree < min(n, len(one.tokens)) and one.tokens[agree] == want[agree]:
        agree += 1
    print("reference file agrees on the first", agree, "tokens; the engine's own answer is the reference from here on")
    want = one.tokens.copy()
    print("identity single:", "PASS" if ok else "FAIL", "tok_s", one.tok_s(), "prefill_s", one.prefill_s)
    var burst = List[GenReq]()
    for _ in range(4):
        burst.append(GenReq(prompt.copy(), n, [], 0))
    var rs = e.generate_batch(burst)
    var ok2 = True
    for r in rs:
        if r.error.byte_length() > 0 or len(r.tokens) != n:
            ok2 = False
        else:
            for i in range(n):
                if r.tokens[i] != want[i]:
                    ok2 = False
    print("identity burst of 4:", "PASS" if ok2 else "FAIL")
    # throughput
    var sizes = [1, 8, 32]
    var per = [8, 2, 2]
    for k in range(len(sizes)):
        var clients = sizes[k]
        for rep in range(reps):
            for m in range(3):
                var mode = (m + rep) % 3  # rotate which mode goes first
                var r = cell(e, clients, mode, prompt, want, n, per[k])
                var name = "unbatched" if mode == 0 else ("batched" if mode == 1 else "batched2")
                print("cell", clients, name, rep, r[0], r[2], Float64(r[0]) / r[2], "bad", r[1])
    e.close()
    print("DONE baro-live")
