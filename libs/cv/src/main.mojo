from mojocv.core import Args, run as run_core


def main() raises:
    var a = Args()
    var ok = run_core(a)
    if not ok:
        print("FAIL main: unknown op", a.op)
        raise Error("unknown op " + a.op)
    if a.reps > 1:
        print("TIME", a.best)
