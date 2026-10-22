"""Adaptive batcher: BentoML's CorkDispatcher for threads.

`Batcher[In, Out].submit(item)` blocks the calling worker thread until its batch has run and returns that item's
output. Batches form by `bento.dispatch.Cork` (the same decisions BentoML makes, replayed in tests/batch_replay.mojo):
one controller thread polls it every millisecond, one thread per batch runs `run_batch`, at most one batch at a time.

Errors: `run_batch` raising fails every item of that batch with its message; an item that waits longer than
`max_latency_ms` fails with "batcher: overloaded" (BentoML answers those with its fallback, an HTTP 503).
"""
from std.ffi import external_call
from std.memory import alloc
from std.time import perf_counter_ns
from bento.dispatch import Cork, IDLE, CANCEL, SLEEP, DISPATCH

comptime QUEUED = 0
comptime OK = 1
comptime FAILED = 2
comptime DROPPED = 3

comptime OVERLOADED = "batcher: overloaded (waited longer than max_latency)"


struct Job[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    var input: Self.In
    var output: Optional[Self.Out]
    var err: String
    var state: Int

    def __init__(out self, var input: Self.In):
        self.input = input^
        self.output = None
        self.err = String()
        self.state = QUEUED


struct Core[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    """Everything the threads share; heap-allocated so its address is stable."""

    var cork: Cork
    var run_batch: def(List[Self.In]) thin raises -> List[Self.Out]
    var jobs: Dict[Int, Int]  # job id -> address of its Job
    var next_id: Int
    var mu: MutPointer[UInt8, MutUntrackedOrigin]  # pthread_mutex_t
    var work: MutPointer[UInt8, MutUntrackedOrigin]  # pthread_cond_t: the controller waits for jobs here
    var done: MutPointer[UInt8, MutUntrackedOrigin]  # pthread_cond_t: submitters and close() wait for results here
    var started: Bool
    var stop: Bool
    var inflight: Int  # batch threads still running
    var ctl: UInt64
    var t0: Int
    var batches: Int
    var items: Int

    def __init__(out self, var cork: Cork, run_batch: def(List[Self.In]) thin raises -> List[Self.Out]):
        self.cork = cork^
        self.run_batch = run_batch
        self.jobs = Dict[Int, Int]()
        self.next_id = 0
        self.mu = alloc[UInt8](64)
        self.work = alloc[UInt8](64)
        self.done = alloc[UInt8](64)
        for i in range(64):
            self.mu[i] = 0
            self.work[i] = 0
            self.done[i] = 0
        self.started = False
        self.stop = False
        self.inflight = 0
        self.ctl = 0
        self.t0 = perf_counter_ns()
        self.batches = 0
        self.items = 0

    def now(self) -> Float64:
        return Float64(perf_counter_ns() - self.t0) / 1e9

    def lock(self):
        _ = external_call["pthread_mutex_lock", Int32](self.mu)

    def unlock(self):
        _ = external_call["pthread_mutex_unlock", Int32](self.mu)

    def wait(self, cond: MutPointer[UInt8, MutUntrackedOrigin]):
        _ = external_call["pthread_cond_wait", Int32](cond, self.mu)

    def broadcast(self, cond: MutPointer[UInt8, MutUntrackedOrigin]):
        _ = external_call["pthread_cond_broadcast", Int32](cond)


struct Batch(Movable):
    """What one batch thread runs: its job ids and when it started."""

    var core: Int  # address of the Core
    var ids: List[Int]
    var start: Float64

    def __init__(out self, core: Int, var ids: List[Int], start: Float64):
        self.core = core
        self.ids = ids^
        self.start = start


def _batch_main[In: Copyable & Deinitable, Out: Copyable & Deinitable](arg: Int) abi("C") -> Int:
    var b = MutPointer[Batch, MutUntrackedOrigin](unsafe_from_address=arg)
    var c = MutPointer[Core[In, Out], MutUntrackedOrigin](unsafe_from_address=b[].core)
    var inputs = List[In]()
    c[].lock()
    for id in b[].ids:
        var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(id, 0))
        inputs.append(j[].input.copy())
    c[].unlock()
    var outs = List[Out]()
    var err = String()
    var failed = False
    try:
        outs = c[].run_batch(inputs)
        if len(outs) != len(inputs):
            raise Error("batcher: run_batch returned " + String(len(outs)) + " outputs for " + String(len(inputs)) + " inputs")
    except e:
        failed = True
        err = String(e)
    c[].lock()
    for k in range(len(b[].ids)):
        var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(b[].ids[k], 0))
        if failed:
            j[].err = err
            j[].state = FAILED
        else:
            j[].output = outs[k].copy()
            j[].state = OK
    if failed:
        c[].cork.failed()
    else:
        c[].cork.done(c[].now(), b[].start)
    c[].batches += 1
    c[].items += len(b[].ids)
    c[].inflight -= 1
    c[].broadcast(c[].done)
    c[].unlock()
    b.unsafe_deinit_pointee()
    b.unsafe_free()
    return 0


def _controller_main[In: Copyable & Deinitable, Out: Copyable & Deinitable](arg: Int) abi("C") -> Int:
    var c = MutPointer[Core[In, Out], MutUntrackedOrigin](unsafe_from_address=arg)
    c[].lock()
    while not c[].stop:
        var now = c[].now()
        var k = c[].cork.step(now)
        if k == IDLE:
            c[].wait(c[].work)
        elif k == CANCEL:
            var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(c[].cork.out_id, 0))
            j[].state = DROPPED
            c[].broadcast(c[].done)
        elif k == SLEEP:
            c[].unlock()
            _ = external_call["usleep", Int32](Int32(1000))
            c[].lock()
        else:
            var b = alloc[Batch](1)
            b.unsafe_write(Batch(arg, c[].cork.out_ids.copy(), now))
            var tid = alloc[UInt64](1)
            var rc = external_call["pthread_create", Int32](tid, Int(0), _batch_main[In, Out], Int(b))
            if rc != 0:
                # no thread for this batch: fail its jobs instead of hanging their submitters
                for id in b[].ids:
                    var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(id, 0))
                    j[].err = "batcher: pthread_create rc " + String(rc)
                    j[].state = FAILED
                c[].cork.failed()
                c[].broadcast(c[].done)
                b.unsafe_deinit_pointee()
                b.unsafe_free()
            else:
                _ = external_call["pthread_detach", Int32](tid[0])
                c[].inflight += 1
            tid.unsafe_free()
    c[].unlock()
    return 0


struct Batcher[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    """Share one Batcher between the worker threads; each calls `submit`."""

    var core: MutPointer[Core[Self.In, Self.Out], MutUntrackedOrigin]

    def __init__(
        out self,
        run_batch: def(List[Self.In]) thin raises -> List[Self.Out],
        max_latency_ms: Int = 10000,
        max_batch_size: Int = 32,
    ):
        self.core = alloc[Core[Self.In, Self.Out]](1)
        self.core.unsafe_write(Core[Self.In, Self.Out](Cork(max_latency_ms, max_batch_size, 0.0), run_batch))

    def submit(self, var item: Self.In) raises -> Self.Out:
        """Queue `item`, block until its batch ran, return its output."""
        var c = self.core
        c[].lock()
        if c[].stop:
            c[].unlock()
            raise Error("batcher: closed")
        if not c[].started:
            var tid = alloc[UInt64](1)
            var rc = external_call["pthread_create", Int32](tid, Int(0), _controller_main[Self.In, Self.Out], Int(c))
            if rc != 0:
                tid.unsafe_free()
                c[].unlock()
                raise Error("batcher: pthread_create rc " + String(rc))
            c[].ctl = tid[0]
            tid.unsafe_free()
            c[].started = True
        var id = c[].next_id
        c[].next_id += 1
        var j = alloc[Job[Self.In, Self.Out]](1)
        j.unsafe_write(Job[Self.In, Self.Out](item^))
        c[].jobs[id] = Int(j)
        c[].cork.enqueue(id, c[].now())
        c[].broadcast(c[].work)
        while j[].state == QUEUED:
            c[].wait(c[].done)
        _ = c[].jobs.pop(id)
        c[].unlock()
        var state = j[].state
        var err = j[].err
        var out = j[].output.take() if state == OK else Optional[Self.Out](None)
        j.unsafe_deinit_pointee()
        j.unsafe_free()
        if state == DROPPED:
            raise Error(OVERLOADED)
        if state == FAILED:
            raise Error(err)
        return out.take()

    def stats(self) -> Tuple[Int, Int]:
        """(batches run, items run) so far."""
        var c = self.core
        c[].lock()
        var r = (c[].batches, c[].items)
        c[].unlock()
        return r

    def close(self):
        """Stop the controller, wait for the running batch, fail every item still queued with "batcher: closed"."""
        var c = self.core
        c[].lock()
        if c[].stop:
            c[].unlock()
            return
        c[].stop = True
        c[].broadcast(c[].work)
        var started = c[].started
        var ctl = c[].ctl
        c[].unlock()
        if started:
            _ = external_call["pthread_join", Int32](ctl, Int(0))
        c[].lock()
        while c[].inflight > 0:
            c[].wait(c[].done)
        for e in c[].jobs.items():
            var j = MutPointer[Job[Self.In, Self.Out], MutUntrackedOrigin](unsafe_from_address=e.value)
            if j[].state == QUEUED:
                j[].err = "batcher: closed"
                j[].state = FAILED
        c[].broadcast(c[].done)
        c[].unlock()
