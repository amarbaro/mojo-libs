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


def _haar(a, inverse, levels):
    n = a.shape[0]
    full = int(np.log2(n))
    nl = int(levels) or full
    a = a.astype(np.float64).copy()
    r = np.sqrt(0.5)
    for k in range(nl):
        m = n >> (nl - 1 - k if inverse else k)
        for ax in range(3):
            v = np.moveaxis(a[:m, :m, :m], ax, 0)  # a view: assignments write through
            if inverse:
                lo, hi = v[: m // 2].copy(), v[m // 2 :].copy()
                v[0::2], v[1::2] = (lo + hi) * r, (lo - hi) * r
            else:
                e, o = v[0::2].copy(), v[1::2].copy()
                v[: m // 2], v[m // 2 :] = (e + o) * r, (e - o) * r
    return a


def haar3f(ins, kv):
    return _haar(ins[0], False, kv.get("levels", 0))


def haar3i(ins, kv):
    return _haar(ins[0], True, kv.get("levels", 0))


def haar3c(ins, kv):
    c = _haar(ins[0], False, kv.get("levels", 0))
    c[np.abs(c) < f(kv, "thr", 0.0)] = 0.0
    return _haar(c, True, kv.get("levels", 0))


def umeyama(ins, kv):
    x, y = ins
    mx, my = x.mean(0), y.mean(0)
    xc, yc = x - mx, y - my
    u, d, vt = np.linalg.svd(yc.T @ xc / len(x))
    sgn = np.ones(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        sgn[2] = -1
    r = u @ np.diag(sgn) @ vt
    c = (d * sgn).sum() / (xc ** 2).sum(1).mean() if int(kv.get("scale", 1)) else 1.0
    m = np.eye(4)
    m[:3, :3] = c * r
    m[:3, 3] = my - c * r @ mx
    return m


OPS = {"voxelize": voxelize, "unvoxelize": unvoxelize, "occupied": occupied, "ohash": ohash, "odiff": odiff,
       "static": static, "umeyama": umeyama, "haar3f": haar3f, "haar3i": haar3i,
       "haar3c": haar3c}


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
    fx.update(align_fixtures())
    fx.update(wavelet_fixtures())
    return fx


def _rot(rs):
    q, r = np.linalg.qr(rs.normal(size=(3, 3)))
    q = q * np.sign(np.diag(r))
    return q if np.linalg.det(q) > 0 else q * np.array([1, 1, -1])


def _sim(s, r, t):
    m = np.eye(4)
    m[:3, :3] = s * r
    m[:3, 3] = t
    return m


def align_fixtures():
    rs = np.random.default_rng(7)
    fx = {}
    src = rs.normal(size=(200, 3)) * [3, 2, 1]
    truth = _sim(1.7, _rot(rs), [4.0, -2.5, 0.75])
    fx["al_src"] = src
    fx["al_truth"] = truth
    fx["al_dst"] = src @ truth[:3, :3].T + truth[:3, 3]
    fx["al_dst_noisy"] = fx["al_dst"] + rs.normal(size=(200, 3)) * 0.05
    plane = src.copy()
    plane[:, 2] = 0
    truth2 = _sim(0.6, _rot(rs), [-1.0, 0.5, 2.0])
    fx["al_plane"] = plane
    fx["al_plane_truth"] = truth2
    fx["al_plane_dst"] = plane @ truth2[:3, :3].T + truth2[:3, 3]
    fx["al_mirror_dst"] = src * [-1, 1, 1]
    fx["al_line"] = np.outer(np.arange(10.0), [1, 2, 3])
    fx["al_few"] = src[:3]
    fx["al_few_dst"] = fx["al_dst"][:3]
    fx["al_one"] = src[:1]
    return fx


def wavelet_fixtures():
    rs = np.random.default_rng(11)
    g = np.linspace(-1, 1, 32)
    z, y, x = np.meshgrid(g, g, g, indexing="ij")
    return {
        "wv_rand8": rs.normal(size=(8, 8, 8)),
        "wv_blob32": np.exp(-4 * (x ** 2 + 2 * y ** 2 + z ** 2)) + 0.01 * rs.normal(size=(32, 32, 32)),
        "wv_const16": np.full((16, 16, 16), 3.0),
        "wv_const_coef": np.pad(np.full((1, 1, 1), 3.0 * 16 ** 1.5), ((0, 15),) * 3),
        "wv_n2": rs.normal(size=(2, 2, 2)),
        "wv_bad6": rs.normal(size=(6, 6, 6)),
    }
