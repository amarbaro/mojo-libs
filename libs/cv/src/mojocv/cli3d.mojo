# 3D / time / CAD / CAE ops for the mojo-cv CLI: `mojo-cv3d OP OUT IN... [k=v]`. src/main.mojo (lane L2D) calls
# dispatch3d for any op it does not know. Every op reads and writes .mcv files; scalars are printed too.
from std.sys import argv
from std.collections import Dict
from mojocv.mat import Mat, load, save
from mojocv.voxel import voxelize, unvoxelize, occupied
from mojocv.align import umeyama
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
