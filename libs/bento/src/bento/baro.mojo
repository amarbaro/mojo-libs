"""The mojo-baro engine as a child process: `Engine` starts it, speaks `baro_wire`, and returns generations.

    Engine(binary, pack) --sh -c 'exec bin <fifo_in >fifo_out'--> engine (BARO_SERVE=1 BARO_PACK=pack)

The engine decodes one request at a time (A3(a): later lines are admitted while one runs, device execution stays
serial). `generate_batch` writes every request line first and then collects the answers, so the engine never idles
between the requests of a batch. One reader thread drains the engine's stdout for the life of the process.
"""
from std.ffi import external_call, c_ssize_t
from std.memory import alloc
from std.time import perf_counter_ns
from posix import spawn, reap, killpg, environ, close
from bento.sync import Mutex, Cond
from bento.baro_wire import (
    GenReq, GenResp, Event, request_line, parse_event, LOG, READY, TOK, DONE, ERROR,
)

comptime _O_WRONLY = 1
comptime _O_RDONLY = 0
comptime _O_NONBLOCK = 0o4000
comptime _F_SETFL = 4


def _cstr(s: String) -> List[UInt8]:
    var b = List[UInt8](capacity=s.byte_length() + 1)
    b.extend(s.as_bytes())
    b.append(0)
    return b^


struct Pending(Movable):
    var tokens: List[Int]
    var finish: String
    var error: String
    var prefill_s: Float64
    var decode_s: Float64
    var state: Int  # 0 running, 1 done, 2 failed

    def __init__(out self):
        self.tokens = List[Int]()
        self.finish = String()
        self.error = String()
        self.prefill_s = 0.0
        self.decode_s = 0.0
        self.state = 0


struct Core(Movable):
    """What the reader thread and the callers share; heap-allocated so its address is stable."""

    var mu: Mutex  # guards everything below except in_fd writes
    var wmu: Mutex  # serialises writes to the engine's stdin (never held together with mu)
    var changed: Cond
    var pending: Dict[Int, Int]  # request id -> address of its Pending
    var next_id: Int
    var ready: Bool
    var dead: Bool  # stdout reached EOF
    var tmax: Int
    var in_fd: Int
    var out_path: String
    var pid: Int
    var reader: UInt64
    var log_lines: Int

    def __init__(out self):
        self.mu = Mutex()
        self.wmu = Mutex()
        self.changed = Cond()
        self.pending = Dict[Int, Int]()
        self.next_id = 1
        self.ready = False
        self.dead = False
        self.tmax = 0
        self.in_fd = -1
        self.out_path = String()
        self.pid = -1
        self.reader = 0
        self.log_lines = 0


def _handle(c: MutPointer[Core, MutUntrackedOrigin], line: String):
    var e = parse_event(line)
    c[].mu.lock()
    if e.kind == LOG:
        c[].log_lines += 1
    elif e.kind == READY:
        c[].ready = True
        c[].tmax = e.tmax
    elif e.kind == TOK or e.kind == DONE or e.kind == ERROR:
        var a = c[].pending.get(e.id, 0)
        if a != 0:
            var p = MutPointer[Pending, MutUntrackedOrigin](unsafe_from_address=a)
            if e.kind == TOK:
                p[].tokens.append(e.tok)
            elif e.kind == DONE:
                p[].finish = e.finish
                p[].prefill_s = e.prefill_s
                p[].decode_s = e.decode_s
                p[].state = 1
            else:
                p[].error = e.error
                p[].state = 2
    c[].changed.broadcast()
    c[].mu.unlock()


def _reader_main(arg: Int) abi("C") -> Int:
    var c = MutPointer[Core, MutUntrackedOrigin](unsafe_from_address=arg)
    var path = _cstr(c[].out_path)
    var fd = Int(external_call["open64", Int32](path.unsafe_ptr(), Int32(_O_RDONLY)))  # blocks until the engine opens its end
    var buf = alloc[UInt8](65536)
    var acc = List[UInt8]()
    while fd >= 0:
        var n = Int(external_call["read", c_ssize_t](Int32(fd), buf, Int(65536)))
        if n <= 0:
            break
        acc.extend(Span(unsafe_ptr=buf, length=n))
        var start = 0
        for i in range(len(acc)):
            if acc[i] == 10:
                _handle(c, String(unsafe_from_utf8=Span(acc)[start:i]))
                start = i + 1
        if start > 0:
            var rest = List[UInt8]()
            rest.extend(Span(acc)[start:])
            acc = rest^
    buf.unsafe_free()
    if fd >= 0:
        close(Int32(fd))
    c[].mu.lock()
    c[].dead = True
    for e in c[].pending.items():
        var p = MutPointer[Pending, MutUntrackedOrigin](unsafe_from_address=e.value)
        if p[].state == 0:
            p[].error = "baro: engine exited"
            p[].state = 2
    c[].changed.broadcast()
    c[].mu.unlock()
    return 0


struct Engine(Movable):
    var core: MutPointer[Core, MutUntrackedOrigin]

    def __init__(
        out self,
        binary: String,
        pack: String,
        run_dir: String,
        cwd: String = "",
        env: List[String] = [],
        ready_timeout_s: Float64 = 600.0,
    ) raises:
        """Start the engine and wait for its ready line. `run_dir` holds the two fifos and engine.log."""
        self.core = alloc[Core](1)
        self.core.unsafe_write(Core())
        var c = self.core
        var fin = run_dir + "/engine.in"
        var fout = run_dir + "/engine.out"
        for f in [fin, fout]:
            var cp = _cstr(f)
            _ = external_call["unlink", Int32](cp.unsafe_ptr())
            if external_call["mkfifo", Int32](cp.unsafe_ptr(), Int32(0o600)) != 0:
                raise Error("baro: mkfifo " + f + " failed")
        c[].out_path = fout
        var tid = alloc[UInt64](1)
        if external_call["pthread_create", Int32](tid, Int(0), _reader_main, Int(c)) != 0:
            raise Error("baro: pthread_create failed")
        c[].reader = tid.unsafe_offset(0)[]
        tid.unsafe_free()
        var e = environ()
        e.append("BARO_SERVE=1")
        e.append("BARO_PACK=" + pack)
        for x in env:
            e.append(x)
        c[].pid = spawn(
            ["sh", "-c", 'exec "$0" <"$1" >"$2" 2>>"$3"', binary, fin, fout, run_dir + "/engine.log"], e, cwd=cwd, new_session=True
        )
        # open the engine's stdin; it opens its end right after the shell starts
        var cin = _cstr(fin)
        var t0 = perf_counter_ns()
        var fd = -1
        while fd < 0:
            fd = Int(external_call["open64", Int32](cin.unsafe_ptr(), Int32(_O_WRONLY | _O_NONBLOCK)))  # ENXIO until a reader exists
            if fd < 0:
                if reap(c[].pid, False):
                    raise Error("baro: engine exited before reading its stdin, see " + run_dir + "/engine.log")
                if Float64(perf_counter_ns() - t0) / 1e9 > 30.0:
                    self._abort()
                    raise Error("baro: engine did not open its stdin within 30 s")
                _ = external_call["usleep", Int32](Int32(10_000))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(_F_SETFL), Int32(0))
        c[].in_fd = fd
        c[].mu.lock()
        var waited = 0.0
        while not c[].ready and not c[].dead and waited < ready_timeout_s:
            _ = c[].changed.timedwait(c[].mu, 1.0)
            waited += 1.0
        var ok = c[].ready
        c[].mu.unlock()
        if not ok:
            self._abort()
            raise Error("baro: engine not ready (exited or timed out), see " + run_dir + "/engine.log")

    def __init__(out self, *, core: Int):
        """A second handle on a running engine, from `address()`: how a Batcher callback (a plain function) finds it."""
        self.core = MutPointer[Core, MutUntrackedOrigin](unsafe_from_address=core)

    def address(self) -> Int:
        return Int(self.core)

    def _abort(self) raises:
        """Kill the engine; a dummy writer on its stdout fifo lets a reader stuck in open() see EOF."""
        var c = self.core
        _ = killpg(c[].pid, 9)
        _ = reap(c[].pid, True)
        var op = _cstr(c[].out_path)
        var fd = Int(external_call["open64", Int32](op.unsafe_ptr(), Int32(_O_WRONLY | _O_NONBLOCK)))
        if fd >= 0:
            close(Int32(fd))
        if c[].in_fd >= 0:
            close(Int32(c[].in_fd))
            c[].in_fd = -1
        _ = external_call["pthread_join", Int32](c[].reader, Int(0))

    def tmax(self) -> Int:
        return self.core[].tmax

    def _write(self, line: String) raises:
        var c = self.core
        c[].wmu.lock()
        var b = line.as_bytes()
        var off = 0
        var ok = c[].in_fd >= 0
        while ok and off < len(b):
            var w = Int(external_call["write", c_ssize_t](Int32(c[].in_fd), b.unsafe_ptr().unsafe_offset(off), len(b) - off))
            if w <= 0:
                ok = False
            else:
                off += w
        c[].wmu.unlock()
        if not ok:
            raise Error("baro: write to the engine failed")

    def submit(self, req: GenReq) raises -> Int:
        """Write one request line; returns its id for `wait`."""
        var c = self.core
        c[].mu.lock()
        if c[].dead:
            c[].mu.unlock()
            raise Error("baro: engine exited")
        var id = c[].next_id
        c[].next_id += 1
        var p = alloc[Pending](1)
        p.unsafe_write(Pending())
        c[].pending[id] = Int(p)
        c[].mu.unlock()
        try:
            self._write(request_line(id, req))
        except e:
            c[].mu.lock()
            _ = c[].pending.pop(id)
            c[].mu.unlock()
            p.unsafe_deinit_pointee()
            p.unsafe_free()
            raise e^
        return id

    def wait(self, id: Int) raises -> GenResp:
        """Block until request `id` has finished; the answer carries `error` when it failed."""
        var c = self.core
        c[].mu.lock()
        var p = MutPointer[Pending, MutUntrackedOrigin](unsafe_from_address=c[].pending.get(id, 0))
        while p[].state == 0:
            c[].changed.wait(c[].mu)
        _ = c[].pending.pop(id)
        c[].mu.unlock()
        var r = GenResp(p[].tokens.copy(), p[].finish, p[].prefill_s, p[].decode_s, p[].error)
        p.unsafe_deinit_pointee()
        p.unsafe_free()
        return r^

    def generate(self, req: GenReq) raises -> GenResp:
        return self.wait(self.submit(req))

    def generate_batch(self, reqs: List[GenReq]) raises -> List[GenResp]:
        """All request lines first (the engine already holds the next request when one finishes), then the answers."""
        var ids = List[Int]()
        for r in reqs:
            ids.append(self.submit(r))
        var out = List[GenResp]()
        for id in ids:
            out.append(self.wait(id))
        return out^

    def close(self) raises:
        """Close the engine's stdin (its clean shutdown), wait up to 30 s for it, then stop the reader."""
        var c = self.core
        if c[].in_fd >= 0:
            close(Int32(c[].in_fd))
            c[].in_fd = -1
        var t0 = perf_counter_ns()
        while not reap(c[].pid, False) and Float64(perf_counter_ns() - t0) / 1e9 < 30.0:
            _ = external_call["usleep", Int32](Int32(20_000))
        _ = killpg(c[].pid, 9)  # whatever is left of its session
        _ = external_call["pthread_join", Int32](c[].reader, Int(0))


@fieldwise_init
struct Call(Copyable, Movable):
    """What a `Batcher[Call, GenResp]` carries: the request and the engine (by address) that should run it."""

    var engine: Int
    var req: GenReq


def run_calls(calls: List[Call]) raises -> List[GenResp]:
    """The Batcher callback: every request of the batch goes to the engine in one burst."""
    var reqs = List[GenReq]()
    for c in calls:
        reqs.append(c.req.copy())
    return Engine(core=calls[0].engine).generate_batch(reqs)
