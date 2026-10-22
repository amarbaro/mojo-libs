from mojocv.core import Args, run as run_core
from mojocv.imgproc import run as run_imgproc
from mojocv.features import run as run_features
from mojocv.video import run as run_video
from mojocv.calib3d import run as run_calib3d


def main() raises:
    var a = Args()
    var ok = run_core(a) or run_imgproc(a) or run_features(a) or run_video(a) or run_calib3d(a)
    if not ok:
        print("FAIL main: unknown op", a.op)
        raise Error("unknown op " + a.op)
    if a.reps > 1:
        print("TIME", a.best)
