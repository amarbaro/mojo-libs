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


def describe(ins, kv):
    p, k = ins[0], int(kv.get("k", 16))
    n = len(p)
    tri = []
    for j in range(64):
        a, b, c = (int(splitmix(np.array([3 * j + t]))[0] % U64(k)) for t in range(3))
        while b == a:
            b = (b + 1) % k
        while c in (a, b):
            c = (c + 1) % k
        tri.append((a, b, c))
    out = np.zeros((n, 8), np.uint8)
    for i in range(n):
        d = p - p[i]
        d2 = (d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1]) + d[:, 2] * d[:, 2]
        d2[i] = np.inf
        nb = np.lexsort((np.arange(n), d2))[:k]
        bits = 0
        for j, (a, b, c) in enumerate(tri):
            u, v, w = p[nb[a]] - p[i], p[nb[b]] - p[i], p[nb[c]] - p[i]
            cx, cy, cz = u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]
            if (cx * w[0] + cy * w[1]) + cz * w[2] > 0:
                bits |= 1 << j
        out[i] = np.frombuffer(bits.to_bytes(8, "little"), np.uint8)
    return out


def match(ins, kv):
    a, b = ins
    ham = np.unpackbits(a[:, None, :] ^ b[None, :, :], axis=2).sum(2)
    idx = ham.argmin(1)  # first minimum = lowest index on ties
    return np.stack([idx, ham[np.arange(len(a)), idx]], 1).astype(np.int32)


def tapvid(ins, kv):
    gt, gv, pr, pv = ins[0], ins[1].reshape(-1) != 0, ins[2], ins[3].reshape(-1) != 0
    err = np.linalg.norm(pr - gt, axis=1)
    apd = aj = 0.0
    for k in range(5):
        delta = 0.01 * 4.0 ** k if int(kv.get("metric", 0)) else 2.0 ** k * gt[:, 2] / f(kv, "focal", 500.0)
        close = err < delta
        tp = (gv & pv & close).sum()
        fp = (pv & ~(gv & close)).sum()
        fn = (gv & ~(pv & close)).sum()
        apd += (gv & close).sum() / gv.sum() / 5
        aj += tp / (tp + fp + fn) / 5
    return np.array([[apd, (gv == pv).mean(), aj]])


def _frac(rm, r0, rp, n):
    nb = max(rm, rp)
    if r0 <= 0 or nb <= 0:
        return 0.0
    rho = nb / r0
    fr = n / np.pi * np.arctan(rho * np.sin(np.pi / n) / (1 + rho * np.cos(np.pi / n)))
    return fr if rp >= rm else -fr


def phasecorr(ins, kv):
    a, b = ins
    rows, cols = a.shape
    if int(kv.get("window", 0)):
        w = np.outer(0.5 * (1 - np.cos(2 * np.pi * np.arange(rows) / (rows - 1))),
                     0.5 * (1 - np.cos(2 * np.pi * np.arange(cols) / (cols - 1))))
        a, b = a * w, b * w
    c = np.fft.fft2(b) * np.conj(np.fft.fft2(a))
    r = np.real(np.fft.ifft2(c / (np.abs(c) + 1e-12)))
    py, px = np.unravel_index(np.argmax(r), r.shape)
    sg = lambda i, n: i - n if i > (n - 1) // 2 else i
    dx = sg(px, cols) + _frac(r[py, (px - 1) % cols], r[py, px], r[py, (px + 1) % cols], cols)
    dy = sg(py, rows) + _frac(r[(py - 1) % rows, px], r[py, px], r[(py + 1) % rows, px], rows)
    return np.array([[dx, dy, r[py, px]]])


def burst(ins, kv):
    nf = len(ins) - (1 if int(kv.get("shifts", 0)) else 0)
    frames = ins[:nf]
    sc = int(kv.get("scale", 2))
    sh = ins[nf] if nf < len(ins) else np.array(
        [[0.0, 0.0]] + [phasecorr([frames[0], fr], kv)[0, :2] for fr in frames[1:]])
    h, w = frames[0].shape
    num, den = np.zeros((h * sc, w * sc)), np.zeros((h * sc, w * sc))
    yy, xx = np.mgrid[0:h, 0:w]
    for fr, (dx, dy) in zip(frames, sh):
        px, py = (xx - dx) * sc, (yy - dy) * sc
        x0, y0 = np.floor(px).astype(int), np.floor(py).astype(int)
        fx, fy = px - x0, py - y0
        for j in (0, 1):
            for i in (0, 1):
                wgt = (fx if i else 1 - fx) * (fy if j else 1 - fy)
                gx, gy = x0 + i, y0 + j
                ok = (gx >= 0) & (gx < w * sc) & (gy >= 0) & (gy < h * sc)
                np.add.at(num, (gy[ok], gx[ok]), (wgt * fr)[ok])
                np.add.at(den, (gy[ok], gx[ok]), wgt[ok])
    gy, gx = np.mgrid[0:h * sc, 0:w * sc]
    sx, sy = np.minimum(gx / sc, w - 1), np.minimum(gy / sc, h - 1)
    ix, iy = np.minimum(sx.astype(int), w - 2), np.minimum(sy.astype(int), h - 2)
    ax, ay = sx - ix, sy - iy
    r = frames[0]
    fill = (1 - ay) * ((1 - ax) * r[iy, ix] + ax * r[iy, ix + 1]) + ay * ((1 - ax) * r[iy + 1, ix] + ax * r[iy + 1, ix + 1])
    return np.where(den > 1e-9, num / np.maximum(den, 1e-300), fill)


def _knots(n, p):
    return np.concatenate([np.zeros(p), np.linspace(0, 1, n - p + 1), np.ones(p)])


def _bsp(n, p, u):
    """Cox-de Boor: basis (len(u), n) and derivative (len(u), n) on the clamped uniform knots."""
    kn = _knots(n, p)
    u = np.asarray(u, float)

    def level(deg):
        m = len(kn) - deg - 1
        if deg == 0:
            b = np.zeros((len(u), len(kn) - 1))
            for i in range(len(kn) - 1):
                if kn[i] < kn[i + 1]:
                    last = kn[i + 1] == 1.0
                    b[:, i] = (u >= kn[i]) & ((u < kn[i + 1]) | (last & (u == 1.0)))
            return b
        lo = level(deg - 1)
        b = np.zeros((len(u), m))
        for i in range(m):
            d1, d2 = kn[i + deg] - kn[i], kn[i + deg + 1] - kn[i + 1]
            if d1 > 0:
                b[:, i] += (u - kn[i]) / d1 * lo[:, i]
            if d2 > 0:
                b[:, i] += (kn[i + deg + 1] - u) / d2 * lo[:, i + 1]
        return b

    b = level(p)
    lo = level(p - 1)
    d = np.zeros_like(b)
    for i in range(n):
        d1, d2 = kn[i + p] - kn[i], kn[i + p + 1] - kn[i + 1]
        if d1 > 0:
            d[:, i] += p * lo[:, i] / d1
        if d2 > 0:
            d[:, i] -= p * lo[:, i + 1] / d2
    return b, d


def nurbs_eval(ins, kv):
    net = ins[0]
    nu, nv = net.shape[:2]
    p, q, m, n = (int(kv.get(k, d)) for k, d in (("p", 3), ("q", 3), ("m", 16), ("n", 16)))
    bu, du = _bsp(nu, p, np.linspace(0, 1, m))
    bv, dv = _bsp(nv, q, np.linspace(0, 1, n))
    pw = np.concatenate([net[..., :3] * net[..., 3:], net[..., 3:]], axis=2)
    h = np.einsum("ai,bj,ijc->abc", bu, bv, pw)
    hu = np.einsum("ai,bj,ijc->abc", du, bv, pw)
    hv = np.einsum("ai,bj,ijc->abc", bu, dv, pw)
    s = h[..., :3] / h[..., 3:]
    su = (hu[..., :3] - hu[..., 3:] * s) / h[..., 3:]
    sv = (hv[..., :3] - hv[..., 3:] * s) / h[..., 3:]
    nrm = np.cross(su, sv)
    nrm = nrm / np.linalg.norm(nrm, axis=2, keepdims=True)
    return np.concatenate([s, nrm], axis=2)


def nurbs_fit(ins, kv):
    g = ins[0]
    nu, nv, p, q = (int(kv.get(k, d)) for k, d in (("nu", 6), ("nv", 6), ("p", 3), ("q", 3)))
    m, n = g.shape[:2]
    bu, _ = _bsp(nu, p, np.linspace(0, 1, m))
    bv, _ = _bsp(nv, q, np.linspace(0, 1, n))
    net = np.ones((nu, nv, 4))
    for c in range(3):
        qm = np.linalg.lstsq(bu, g[..., c], rcond=None)[0]
        net[..., c] = np.linalg.lstsq(bv, qm.T, rcond=None)[0].T
    return net


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
       "haar3c": haar3c, "tapvid": tapvid, "phasecorr": phasecorr, "nurbs_eval": nurbs_eval, "nurbs_fit": nurbs_fit, "burst": burst, "describe": describe, "match": match}


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
    fx.update(desc_fixtures())
    fx.update(tap_fixtures())
    fx.update(pc_fixtures())
    fx.update(burst_fixtures())
    fx.update(nurbs_fixtures())
    fx.update(mesh_fixtures())
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


def desc_fixtures():
    """A cloud whose descriptors are pairwise >= 7 bits apart, so 3 planted bit flips cannot change the match."""
    for seed in range(13, 200):
        rs = np.random.default_rng(seed)
        n = 100
        p = rs.normal(size=(n, 3))
        da = describe([p], {})
        ham = np.unpackbits(da[:, None, :] ^ da[None, :, :], axis=2).sum(2)
        np.fill_diagonal(ham, 99)
        if ham.min() >= 7:
            break
    t = _sim(2.5, _rot(rs), [1.0, -3.0, 0.5])
    perm = rs.permutation(n)
    db = da[perm].copy()
    for i in range(n):  # three flipped bits per descriptor
        for bit in rs.choice(64, 3, replace=False):
            db[i, bit // 8] ^= 1 << (bit % 8)
    return {
        "ds_pts": p,
        "ds_pts_moved": p @ t[:3, :3].T + t[:3, 3],
        "ds_few": p[:10],
        "ds_pts_mirror": p * [-1, 1, 1],
        "ds_desc_not": np.bitwise_not(da),
        "ds_ident": np.stack([np.arange(n), np.zeros(n)], 1).astype(np.int32),
        "ds_noisy": db,
        "ds_noisy_truth": np.stack([np.argsort(perm), np.full(n, 3)], 1).astype(np.int32),
        "ds_one": da[:1],
        "ds_empty": np.zeros((0, 8), np.uint8),
    }


def tap_fixtures():
    rs = np.random.default_rng(17)
    m = 400
    gt = np.column_stack([rs.normal(size=(m, 2)), rs.uniform(5, 15, m)])
    gv = (rs.random(m) < 0.7).astype(np.uint8)
    flip = rs.random(m) < 0.1
    one = np.ones((4, 1), np.uint8)
    z10 = np.column_stack([rs.normal(size=(4, 2)), np.full(4, 10.0)])
    return {
        "tp_gt": gt, "tp_gv": gv.reshape(-1, 1),
        "tp_pred": gt + rs.normal(size=(m, 3)) * 0.1,
        "tp_pv": (gv ^ flip).astype(np.uint8).reshape(-1, 1),
        "tp_perfect": np.array([[1.0, 1.0, 1.0]]),
        "tp_z10": z10, "tp_z10_off": z10 + [0.05, 0, 0], "tp_one": one,
        "tp_z10_truth": np.array([[0.6, 1.0, 0.6]]),
        "tp_c_gv": np.array([[1], [1], [0], [0]], np.uint8), "tp_c_pv": np.array([[1], [0], [1], [0]], np.uint8),
        "tp_c_truth": np.array([[1.0, 0.5, 1 / 3]]),
        "tp_zero": np.zeros((4, 1), np.uint8),
    }


def fshift(img, dy, dx):
    """Periodic (Fourier) translation by a fractional amount: b(x) = a(x - d)."""
    ky = np.fft.fftfreq(img.shape[0])[:, None]
    kx = np.fft.fftfreq(img.shape[1])[None, :]
    return np.real(np.fft.ifft2(np.fft.fft2(img) * np.exp(-2j * np.pi * (ky * dy + kx * dx))))


def pc_fixtures():
    rs = np.random.default_rng(19)
    fx = {}
    for tag, shp in (("", (64, 96)), ("odd", (45, 60)), ("prime", (31, 37))):
        a = rs.random(shp)
        dy, dx = 5 % shp[0], -7
        fx["pc_a" + tag] = a
        fx["pc_b" + tag] = np.roll(a, (dy, dx), (0, 1))
        fx["pc_t" + tag] = np.array([[dx, dy if dy <= (shp[0] - 1) // 2 else dy - shp[0], 1.0]])
    a = rs.random((65, 97))
    fx["pc_af"] = a
    fx["pc_bf"] = fshift(a, 2.5, -3.25)
    fx["pc_tf"] = np.array([[-3.25, 2.5]])
    fx["pc_bf2"] = fshift(a, 0.77, -0.3)
    fx["pc_tf2"] = np.array([[-0.3, 0.77]])
    fx["pc_bnoise"] = np.roll(a, (3, 4), (0, 1)) + 0.2 * rs.random((65, 97))
    fx["pc_zero"] = np.zeros((16, 16))
    fx["pc_zt"] = np.zeros((1, 3))
    fx["pc_small"] = rs.random((8, 8))
    return fx


def burst_fixtures():
    """A smooth periodic fine image H and four LR frames sampled half an LR pixel apart (each fine pixel is hit once)."""
    rs = np.random.default_rng(23)
    h, w = 24, 32
    spec = np.zeros((h, w), complex)
    for ky in range(-3, 4):
        for kx in range(-3, 4):
            if (ky, kx) != (0, 0):
                spec[ky % h, kx % w] = rs.normal() + 1j * rs.normal()
    hr = np.real(np.fft.ifft2(spec)) * h * w / 20 + 0.5
    frames = {}
    for t, (sx, sy) in enumerate([(0, 0), (1, 0), (0, 1), (1, 1)]):  # shifts in fine pixels
        frames[f"bs_f{t}"] = np.roll(hr, (sy, sx), (0, 1))[::2, ::2].copy()
    # np.roll content by +s means frame(x) = hr(2x - s): the shift of frame t in LR pixels is s / 2
    frames["bs_shifts"] = np.array([[0, 0], [0.5, 0], [0, 0.5], [0.5, 0.5]])
    frames["bs_hr"] = hr
    # broadband frames (all spectrum bins informative, odd sizes: exact Fourier shifts) for the registration rows
    r0 = rs.random((13, 17))
    for t, (sx, sy) in enumerate([(0, 0), (0.5, 0), (0, 0.5), (0.5, 0.5)]):
        frames[f"bs_r{t}"] = fshift(r0, sy, sx)
    frames["bs_rn"] = frames["bs_r3"] + 0.05 * rs.random((13, 17))
    return frames


def nurbs_fixtures():
    rs = np.random.default_rng(29)
    fx = {}
    net = np.ones((6, 5, 4))
    net[..., :3] = rs.normal(size=(6, 5, 3))
    fx["ns_net"] = net
    netw = net.copy()
    netw[..., 3] = rs.uniform(0.5, 2.0, (6, 5))
    fx["ns_netw"] = netw
    grid = nurbs_eval([net], {"p": 3, "q": 2, "m": 30, "n": 25})[..., :3]
    fx["ns_grid"] = grid
    fx["ns_grid_noisy"] = grid + 0.01 * rs.normal(size=grid.shape)
    fx["ns_grid_small"] = grid[:4, :4]
    # plane: control points at the Greville abscissae reproduce (u, v, 0) exactly
    ku, kv_ = _knots(6, 3), _knots(5, 2)
    gu = np.array([ku[i + 1:i + 4].mean() for i in range(6)])
    gv = np.array([kv_[j + 1:j + 3].mean() for j in range(5)])
    plane = np.ones((6, 5, 4))
    plane[..., 0], plane[..., 1], plane[..., 2] = gu[:, None], gv[None, :], 0.0
    fx["ns_plane"] = plane
    u, v = np.meshgrid(np.linspace(0, 1, 9), np.linspace(0, 1, 7), indexing="ij")
    fx["ns_plane_truth"] = np.concatenate(
        [np.stack([u, v, 0 * u], 2), np.broadcast_to([0.0, 0.0, 1.0], (9, 7, 3))], axis=2)
    cyl = np.ones((3, 2, 4))
    for i, (x, y, w) in enumerate([(1, 0, 1), (1, 1, np.sqrt(0.5)), (0, 1, 1)]):
        for j in range(2):
            cyl[i, j] = [x, y, j, w]
    fx["ns_cyl"] = cyl
    return fx


# --- ops whose result is not one array: custom checks, ctx = dict(name, ins, args, expect, work, run, mcv) ---
def mesh_invariants(v, f):
    """Closed-surface facts of a triangle mesh, computed independently of the Mojo code."""
    e = np.sort(np.concatenate([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]]), axis=1)
    uniq, cnt = np.unique(e, axis=0, return_counts=True)
    p0, p1, p2 = v[f[:, 0]], v[f[:, 1]], v[f[:, 2]]
    vol = float(np.einsum("ij,ij->i", p0, np.cross(p1, p2)).sum() / 6)
    area = float(0.5 * np.linalg.norm(np.cross(p1 - p0, p2 - p0), axis=1).sum())
    manifold = True
    link = {}
    for a, b, c in f.tolist():
        link.setdefault(a, []).append((b, c))
        link.setdefault(b, []).append((c, a))
        link.setdefault(c, []).append((a, b))
    for vtx, segs in link.items():  # the triangles around a vertex must close into ONE cycle
        nxt = dict(segs)
        if len(nxt) != len(segs):
            manifold = False
            break
        start = segs[0][0]
        cur, steps = start, 0
        while True:
            cur = nxt.get(cur)
            steps += 1
            if cur is None or cur == start or steps > len(segs):
                break
        manifold &= cur == start and steps == len(segs)
    return dict(V=len(v), E=len(uniq), F=len(f), edges_twice=bool((cnt == 2).all()), vol=vol, area=area,
                chi=len(v) - len(uniq) + len(f), manifold=manifold, unused=len(set(range(len(v))) - set(f.ravel().tolist())))


def check_mesh(ctx):
    cells = ctx["mcv"].load(ctx["ins"][0])
    out, faces = ctx["work"] / f"{ctx['name']}.v.mcv", ctx["work"] / f"{ctx['name']}.f.mcv"
    code, stdout, stderr = ctx["run"](out, ctx["ins"], ctx["args"] + [f"faces={faces}"])
    if code != 0:
        return False, f"exit {code}: {(stdout + stderr).strip()[:200]}"
    v, f = ctx["mcv"].load(out), ctx["mcv"].load(faces).astype(int)
    inv = mesh_invariants(v, f)
    cs = set(map(tuple, cells.tolist()))
    quads = sum((c[0] + d[0], c[1] + d[1], c[2] + d[2]) not in cs for c in cs
                for d in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)))
    bad = [k for k, ok in (("edges not on exactly two faces", inv["edges_twice"]), ("vertex fan not one cycle", inv["manifold"]),
                           ("faces != 2 x boundary quads", inv["F"] == 2 * quads),
                           ("area != boundary quads", abs(inv["area"] - quads) < 1e-9),
                           ("signed volume != cell count (orientation or closure)", abs(inv["vol"] - len(cs)) < 1e-9),
                           ("unused vertex", inv["unused"] == 0)) if not ok]
    for k, val in ctx["expect"].items():
        if k in ("V", "chi") and inv[k] != int(val):
            bad.append(f"{k} {inv[k]} != {val}")
    if f"V={inv['V']} E={inv['E']} F={inv['F']} chi={inv['chi']}".replace("=", "=") and f"chi= {inv['chi']}" not in stdout:
        bad.append("printed chi differs from independent chi")
    print(f"     {ctx['name']}: V={inv['V']} E={inv['E']} F={inv['F']} chi={inv['chi']} volume={inv['vol']:g} area={inv['area']:g}")
    return not bad, "; ".join(bad)


CUSTOM = {"mesh": check_mesh}


def mesh_fixtures():
    def box(a, b, c, o=(0, 0, 0)):
        return [(x + o[0], y + o[1], z + o[2]) for x in range(a) for y in range(b) for z in range(c)]
    arr = lambda cs: np.array(sorted(set(cs)), np.int32).reshape(-1, 3)
    ring = [c for c in box(3, 3, 1) if c != (1, 1, 0)]
    shell = [c for c in box(3, 3, 3) if c != (1, 1, 1)]
    rs = np.random.default_rng(31)
    blob = np.unique(rs.integers(0, 6, (120, 3)), axis=0).astype(np.int32)
    return {
        "ms_one": arr([(0, 0, 0)]), "ms_cube3": arr(box(3, 3, 3)), "ms_bar": arr(box(4, 1, 2)),
        "ms_ring": arr(ring), "ms_shell": arr(shell), "ms_two": arr(box(1, 1, 1) + box(1, 1, 1, (3, 0, 0))),
        "ms_edge": arr([(0, 0, 0), (1, 1, 0)]), "ms_corner": arr([(0, 0, 0), (1, 1, 1)]),
        "ms_L": arr(box(2, 1, 1) + box(1, 2, 1) + box(1, 1, 2)), "ms_blob": blob,
        "ms_neg": arr([(-1, -1, -1), (0, -1, -1)]),
        # two cells touching along one edge whose end points are each joined through a chain of cells below and above
        "ms_pinch": arr([(0, 0, 1), (1, 1, 1), (0, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 2), (1, 1, 2), (0, 1, 2)]),
    }
