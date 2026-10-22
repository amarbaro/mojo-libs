from mojocv.core import Args, run as run_core
from mojocv.imgproc import run as run_imgproc


def main() raises:
    var a = Args()
    var ok = run_core(a) or run_imgproc(a)
    if not ok:
        print("FAIL main: unknown op", a.op)
        raise Error("unknown op " + a.op)
    if a.reps > 1:
        print("TIME", a.best)
