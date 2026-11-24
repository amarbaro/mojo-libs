from std.sys import argv
from mojocv.core import Args, run as run_core
from mojocv.imgproc import run as run_imgproc
from mojocv.features import run as run_features
from mojocv.video import run as run_video
from mojocv.calib3d import run as run_calib3d
from mojocv.cli3d import dispatch3d
from mojocv.granulo import run as run_granulo
from mojocv.stockcheck import run as run_stockcheck
from mojocv.stockphoto import run as run_stockphoto
from mojocv.stockgroup import run as run_stockgroup
from mojocv.gpu import run as run_gpu
from mojocv.regions import run as run_regions
from mojocv.ruler import run as run_ruler
from mojocv.hyper import run as run_hyper
from mojocv.calib import run as run_calib
from mojocv.embindex import run as run_embindex


def main() raises:
    var a = Args()
    var ok = run_gpu(a) or run_core(a) or run_imgproc(a) or run_features(a) or run_video(a) or run_calib3d(a) or run_granulo(a) or run_stockcheck(a) or run_stockphoto(a) or run_stockgroup(a) or run_regions(a) or run_ruler(a) or run_hyper(a) or run_calib(a) or run_embindex(a)
    if not ok:
        var v = List[String]()
        var av = argv()
        for i in range(1, len(av)):
            v.append(String(av[i]))
        ok = dispatch3d(v)
    if not ok:
        print("FAIL main: unknown op", a.op)
        raise Error("unknown op " + a.op)
    if a.reps > 1:
        print("TIME", a.best)
