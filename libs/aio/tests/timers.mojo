# Timers fire in deadline order, never early, median lateness under 1.5 ms (the loop has 1 ms resolution) and none 20 ms late (a shared runner preempts us
# for a few ms at a time, which makes a whole batch of same-millisecond timers late at once); wait() honours its timeout.
from std.random import seed, random_ui64
from std.time import perf_counter_ns
from std.builtin.sort import sort
import aio


def main() raises:
    var loop = aio.Loop()
    var evs = List[aio.Event]()
    seed(7)
    var n = 2000
    var due = List[Int](length=n, fill=0)
    var t0 = Int(perf_counter_ns())
    for i in range(n):
        due[i] = Int(random_ui64(0, 60))
        loop.after(due[i], UInt64(i))
    var seen = 0
    var last = -1
    var lates = List[Int](capacity=n)
    while seen < n:
        _ = loop.wait(evs)
        var now = Int(perf_counter_ns())
        for ev in evs:
            if not (ev.events & aio.TIMER):
                raise Error("FAIL timers: non-timer event")
            var i = Int(ev.token)
            var late = now - t0 - due[i] * 1_000_000
            if late < 0 or due[i] < last:
                raise Error(String("FAIL timers: timer ", i, " early or out of order"))
            last = due[i]
            lates.append(late)
            seen += 1
    sort(lates)
    var median = lates[n // 2]
    var worst = lates[n - 1]
    if median > 1_500_000 or worst > 20_000_000:
        raise Error(String("FAIL timers: median lateness ", median // 1000, " us, worst ", worst // 1000, " us"))
    var s = Int(perf_counter_ns())
    if loop.wait(evs, 20) != 0 or Int(perf_counter_ns()) - s < 20_000_000:
        raise Error("FAIL timers: wait(20) returned early or with events")
    print("timers", n, "ordered, median lateness", median // 1000, "us, worst", worst // 1000, "us")
