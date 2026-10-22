"""Independent numpy oracles for the L3D ops (brute force or closed form), plus the fixture generator.
OPS[op](inputs, kv) -> ndarray, same shape/dtype as the Mojo op writes."""
import numpy as np

U64 = np.uint64
GOLD = U64(0x9E3779B97F4A7C15)
rng = np.random.default_rng(20261022)


def splitmix(x):
    with np.errstate(over="ignore"):
        z = x.astype(U64) + GOLD
        z = (z ^ (z >> U64(30))) * U64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> U64(27))) * U64(0x94D049BB133111EB)
        return z ^ (z >> U64(31))


def zkey(axis, v):
    return splitmix((U64(axis + 1) << U64(40)) + v.astype(U64))


def cell_hash(c):
    c = c.astype(np.int64)
    return splitmix(zkey(0, c[:, 0]) ^ zkey(1, c[:, 1]) ^ zkey(2, c[:, 2]))


def f(kv, k, d):
    return float(kv.get(k, d))


def voxelize(ins, kv):
    s = ins[0] / f(kv, "size", 1.0)
    c = np.floor(s)
    return np.hstack([c, s - c])


def unvoxelize(ins, kv):
    v = ins[0]
    return (v[:, :3] + v[:, 3:]) * f(kv, "size", 1.0)


def occupied(ins, kv):
    return np.unique(np.floor(ins[0] / f(kv, "size", 1.0)).astype(np.int32), axis=0)


def ohash(ins, kv):
    h = np.bitwise_xor.reduce(cell_hash(ins[0])) if len(ins[0]) else U64(0)
    return np.frombuffer(np.array([h], dtype="<u8").tobytes(), np.uint8).reshape(1, 8)


def _sets(ins):
    return [set(map(tuple, a.tolist())) for a in ins]


def odiff(ins, kv):
    a, b = _sets(ins)
    return np.array(sorted(a ^ b), dtype=np.int32).reshape(-1, 3)


def static(ins, kv):
    sets = _sets(ins)
    allc = sorted(set().union(*sets))
    return np.array([(*c, int(all(c in s for s in sets))) for c in allc], dtype=np.int32).reshape(-1, 4)


OPS = {"voxelize": voxelize, "unvoxelize": unvoxelize, "occupied": occupied, "ohash": ohash, "odiff": odiff,
       "static": static}


def fixtures():
    """name -> ndarray; written as .mcv by the driver."""
    fx = {}
    pts = rng.uniform(-8, 8, (500, 3))
    fx["pts500"] = pts
    fx["pts_dup"] = np.vstack([pts[:50], pts[:50] + 1e-3, pts[:10]])
    fx["pts_empty"] = np.zeros((0, 3))
    scene = np.unique(rng.integers(0, 64, (3000, 3)), axis=0).astype(np.int32)
    fx["scene64"] = scene
    extra = np.array([[63, 63, 63]], np.int32) if not (scene == 63).all(1).any() else np.array([[0, 0, 0]], np.int32)
    fx["scene64_add1"] = np.vstack([scene, extra])
    fx["scene64_rm1"] = scene[1:]
    # four cells on a rectangle: raw per-axis Zobrist XOR cancels them, the mixed hash must not
    rect = np.array([[5, 7, 9], [50, 7, 9], [5, 40, 9], [50, 40, 9]], np.int32)
    rect = np.array([r for r in rect if not (scene == r).all(1).any()], np.int32)
    fx["scene64_rect"] = np.vstack([scene, rect])
    fx["rect_len"] = np.array([[len(rect)]], np.int32)
    fx["cells_empty"] = np.zeros((0, 3), np.int32)
    # static/moving window: a fixed room plus a block that walks along x
    room = np.array([(x, y, 0) for x in range(16) for y in range(16)], np.int32)
    fx["frame0"] = np.vstack([room, [[3, 3, 5], [3, 3, 6]]]).astype(np.int32)
    fx["frame1"] = np.vstack([room, [[4, 3, 5], [4, 3, 6]]]).astype(np.int32)
    fx["frame2"] = np.vstack([room[:-1], [[5, 3, 5], [5, 3, 6]]]).astype(np.int32)
    return fx
