# 3D / time / CAD / CAE ops for the mojo-cv CLI: `mojo-cv3d OP OUT IN... [k=v]`. src/main.mojo (lane L2D) calls
# dispatch3d for any op it does not know. Every op reads and writes .mcv files; scalars are printed too.
from std.sys import argv
from std.time import perf_counter_ns
from std.collections import Dict
from mojocv.mat import Mat, load, save
from mojocv.voxel import voxelize, unvoxelize, occupied
from mojocv.align import umeyama
from mojocv.wavelet import haar3, compress
from mojocv.desc3d import describe, match_desc
from mojocv.tapvid import tapvid
from mojocv.phasecorr import phase_corr
from mojocv.burst import burst, register
from mojocv.nurbs import eval_surface, fit_surface
from mojocv.octree import Octree, walk, walk_cells


def _f(kv: Dict[String, String], name: String, dflt: Float64) raises -> Float64:
    return Float64(kv[name]) if name in kv else dflt


def _i(kv: Dict[String, String], name: String, dflt: Int) raises -> Int:
    return Int(kv[name]) if name in kv else dflt


def _trees(ins: List[String], depth: Int) raises -> List[Octree]:
    var ts = List[Octree]()
    for p in ins:
        ts.append(Octree(load[DType.int32](p), depth))
    return ts^


def dispatch3d(args: List[String]) raises -> Bool:
    """Args = OP OUT IN... [k=v...]; True when the op belongs to this module set."""
    if len(args) < 2:
        return False
    var op = args[0]
    var out = args[1]
    var ins = List[String]()
    var kv = Dict[String, String]()
    for i in range(2, len(args)):
        var eq = args[i].find("=")
        if eq > 0:
            kv[String(args[i][byte=:eq])] = String(args[i][byte=eq + 1 :])
        else:
            ins.append(args[i])
    if op == "voxelize":
        save(voxelize(load[DType.float64](ins[0]), _f(kv, "size", 1.0)), out)
    elif op == "unvoxelize":
        save(unvoxelize(load[DType.float64](ins[0]), _f(kv, "size", 1.0)), out)
    elif op == "occupied":
        save(occupied(load[DType.float64](ins[0]), _f(kv, "size", 1.0)), out)
    elif op == "ohash":
        var t = Octree(load[DType.int32](ins[0]), _i(kv, "depth", 6))
        var h = Mat[DType.uint8](1, 8)
        for i in range(8):
            h.data[i] = UInt8((t.root_hash() >> UInt64(8 * i)) & 0xFF)
        print("ohash cells=", t.cells())
        save(h, out)
    elif op == "odiff" or op == "static":
        var depth = _i(kv, "depth", 6)
        var w = walk(_trees(ins, depth), op == "static")
        print(op, "visited=", w.visited, "dense=", 1 << (3 * depth), "out=", len(w.keys))
        save(walk_cells(w, op == "static"), out)
    elif op == "umeyama":
        save(umeyama(load[DType.float64](ins[0]), load[DType.float64](ins[1]), _i(kv, "scale", 1) != 0), out)
    elif op == "haar3f" or op == "haar3i":
        var v = load[DType.float64](ins[0])
        save(haar3[False](v, _i(kv, "levels", 0)) if op == "haar3f" else haar3[True](v, _i(kv, "levels", 0)), out)
    elif op == "haar3c":
        var v = load[DType.float64](ins[0])
        var r = compress(v, _f(kv, "thr", 0.0), _i(kv, "levels", 0))
        print("haar3c kept=", r[1], "of=", v.size())
        save(r[0], out)
    elif op == "describe":
        save(describe(load[DType.float64](ins[0]), _i(kv, "k", 16)), out)
    elif op == "match":
        save(match_desc(load[DType.uint8](ins[0]), load[DType.uint8](ins[1])), out)
    elif op == "tapvid":
        var r = tapvid(
            load[DType.float64](ins[0]), load[DType.uint8](ins[1]), load[DType.float64](ins[2]),
            load[DType.uint8](ins[3]), _f(kv, "focal", 500.0), _i(kv, "metric", 0) != 0,
        )
        print("tapvid apd=", r.data[0], "oa=", r.data[1], "aj=", r.data[2])
        save(r, out)
    elif op == "phasecorr":
        var a = load[DType.float64](ins[0])
        var b = load[DType.float64](ins[1])
        var r = phase_corr(a, b, _i(kv, "window", 0) != 0)
        var best = Int.MAX
        for _ in range(_i(kv, "reps", 0)):  # best-of-reps in this process, for docs/bench.md
            var t0 = Int(perf_counter_ns())
            r = phase_corr(a, b, _i(kv, "window", 0) != 0)
            best = min(best, Int(perf_counter_ns()) - t0)
        if best != Int.MAX:
            print("phasecorr best_ms=", Float64(best) / 1e6)
        save(r, out)
    elif op == "burst":
        # IN... = frames, then (shifts=1) a T x 2 float64 file of known [dx, dy]; otherwise phase correlation finds them
        var frames = List[Mat[DType.float64]]()
        var nf = len(ins) - (1 if _i(kv, "shifts", 0) != 0 else 0)
        for i in range(nf):
            frames.append(load[DType.float64](ins[i]))
        var sh = load[DType.float64](ins[nf]) if nf < len(ins) else register(frames, _i(kv, "window", 0) != 0)
        for t in range(sh.rows):
            print("burst shift", t, sh.data[t * 2], sh.data[t * 2 + 1])
        save(burst(frames, sh, _i(kv, "scale", 2)), out)
    elif op == "nurbs_fit":
        save(fit_surface(load[DType.float64](ins[0]), _i(kv, "nu", 6), _i(kv, "nv", 6), _i(kv, "p", 3), _i(kv, "q", 3)), out)
    elif op == "nurbs_eval":
        save(
            eval_surface(
                load[DType.float64](ins[0]), _i(kv, "p", 3), _i(kv, "q", 3), _i(kv, "m", 16), _i(kv, "n", 16)
            ),
            out,
        )
    else:
        return False
    return True


def main() raises:
    var a = List[String]()
    var av = argv()
    for i in range(1, len(av)):
        a.append(String(av[i]))
    if not dispatch3d(a):
        print("FAIL cli3d: unknown op or too few arguments")
        raise Error("cli3d")
