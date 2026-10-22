"""Stand-in for lane B's batch.mojo until it merges: same type parameters, `submit` and `close`, a batch of
one. An endpoint that holds a Batcher needs no change when the real one replaces this file."""


struct Batcher[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    var run_batch: def(List[Self.In]) thin raises -> List[Self.Out]

    def __init__(out self, run_batch: def(List[Self.In]) thin raises -> List[Self.Out]):
        self.run_batch = run_batch

    def submit(self, var item: Self.In) raises -> Self.Out:
        """Run `item` alone through run_batch and return its answer."""
        var batch = List[Self.In]()
        batch.append(item^)
        var out = self.run_batch(batch^)
        if len(out) != 1:
            raise Error("batcher: run_batch returned ", len(out), " results for 1 input")
        return out.pop()

    def close(self):
        pass
