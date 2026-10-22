"""cv2 5.0 oracle and test driver for mojo-cv.

  oracle_cv2.py OP OUT IN... [k=v]     run one op exactly as `.bin/mojo-cv OP OUT IN... [k=v]` would
  oracle_cv2.py --fixtures DIR         write the .mcv inputs the case rows name
  oracle_cv2.py --suite [--bench] CASES...   run every row through ours and cv2, compare, print PASS/FAIL

A case row is `id op IN... [k=v...] => cmp[, cmp...]`; one cmp per output file (OUT, OUT.1, ...):
  exact | max:T | mean:T | frac:T:F (share of values within T) | iou:F (nonzero masks)
  pts:T:F (share of ref rows with one of ours within distance T) | cnt:R (|n_ours - n_ref| <= R * n_ref)
"""
import os, re, subprocess, sys, time, struct
import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import mcv

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "tests", "fixtures")
DT = {0: np.uint8, 1: np.float32, 2: np.int32, 3: np.float64, 4: np.int16}
OPS = {}


def op(*names):
    def deco(f):
        for n in names or [f.__name__]:
            OPS[n] = f
        return f
    return deco


def kv_f(kv, k, d):
    return float(kv[k]) if k in kv else d


def kv_i(kv, k, d):
    return int(float(kv[k])) if k in kv else d


# ---- core -------------------------------------------------------------------------------------------------
@op()
def flip(i, kv): return cv2.flip(i[0], kv_i(kv, "code", 1))
@op()
def rotate(i, kv): return cv2.rotate(i[0], [cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_180, cv2.ROTATE_90_COUNTERCLOCKWISE][kv_i(kv, "code", 0)])
@op()
def transpose(i, kv): return cv2.transpose(i[0])
@op()
def absdiff(i, kv): return cv2.absdiff(i[0], i[1])
@op()
def bitwise_and(i, kv): return cv2.bitwise_and(i[0], i[1])
@op()
def bitwise_or(i, kv): return cv2.bitwise_or(i[0], i[1])
@op()
def bitwise_xor(i, kv): return cv2.bitwise_xor(i[0], i[1])
@op()
def bitwise_not(i, kv): return cv2.bitwise_not(i[0])
@op()
def convert(i, kv):
    """convertTo: saturate_cast(round_half_even(a * alpha + beta)), computed in float64."""
    dt = DT[kv_i(kv, "to", 0)]
    r = i[0].astype(np.float64) * kv_f(kv, "alpha", 1.0) + kv_f(kv, "beta", 0.0)
    if np.issubdtype(dt, np.integer):
        r = np.clip(np.rint(r), np.iinfo(dt).min, np.iinfo(dt).max)
    return r.astype(dt)


# ---- imgproc ----------------------------------------------------------------------------------------------
@op()
def GaussianBlur(i, kv):
    k = kv_i(kv, "ksize", 5)
    return cv2.GaussianBlur(i[0], (k, k), kv_f(kv, "sigma", 0.0))
@op()
def pyrDown(i, kv): return cv2.pyrDown(i[0])
@op()
def Sobel(i, kv):
    return cv2.Sobel(i[0], cv2.CV_16S if i[0].dtype == np.uint8 else -1, kv_i(kv, "dx", 1), kv_i(kv, "dy", 0),
                     ksize=kv_i(kv, "ksize", 3), scale=kv_f(kv, "scale", 1.0))


@op()
def threshold(i, kv):
    t, mv = kv_f(kv, "thresh", 127.0), kv_f(kv, "maxval", 255.0)
    ty = kv_i(kv, "type", 0) | (cv2.THRESH_OTSU if kv_i(kv, "otsu", 0) else 0)
    r, o = cv2.threshold(i[0], t, mv, ty)
    return [o, np.array([[r]], np.float64)]
@op()
def integral(i, kv): return cv2.integral(i[0], sdepth=cv2.CV_32S if i[0].dtype == np.uint8 else cv2.CV_64F)
SHAPES = [cv2.MORPH_RECT, cv2.MORPH_CROSS, cv2.MORPH_ELLIPSE]
def _se(kv):
    k = kv_i(kv, "ksize", 3)
    return cv2.getStructuringElement(SHAPES[kv_i(kv, "shape", 0)], (k, k))
@op()
def erode(i, kv): return cv2.erode(i[0], _se(kv), iterations=kv_i(kv, "iters", 1))
@op()
def dilate(i, kv): return cv2.dilate(i[0], _se(kv), iterations=kv_i(kv, "iters", 1))
@op()
def cvtColor(i, kv):
    c = {"bgr2gray": cv2.COLOR_BGR2GRAY, "rgb2gray": cv2.COLOR_RGB2GRAY, "gray2bgr": cv2.COLOR_GRAY2BGR, "bgr2rgb": cv2.COLOR_BGR2RGB,
         "bgr2hsv": cv2.COLOR_BGR2HSV, "hsv2bgr": cv2.COLOR_HSV2BGR, "bgr2ycrcb": cv2.COLOR_BGR2YCrCb, "ycrcb2bgr": cv2.COLOR_YCrCb2BGR}
    return cv2.cvtColor(i[0], c[kv["code"]])


# ---- compare ----------------------------------------------------------------------------------------------
def compare(ours, ref, spec):
    if ours.shape != ref.shape:
        return False, f"shape {ours.shape} vs {ref.shape}"
    if ours.dtype != ref.dtype:
        return False, f"dtype {ours.dtype} vs {ref.dtype}"
    k, *p = spec.split(":")
    p = [float(x) for x in p]
    o, r = ours.astype(np.float64), ref.astype(np.float64)
    d = np.abs(o - r)
    if k == "exact":
        return bool((d == 0).all()), f"maxdiff {d.max() if d.size else 0}"
    if k == "max":
        return bool((d <= p[0]).all()), f"maxdiff {d.max() if d.size else 0} (tol {p[0]})"
    if k == "mean":
        return bool(d.mean() <= p[0]), f"meandiff {d.mean():.4g} (tol {p[0]})"
    if k == "frac":
        f = (d <= p[0]).mean() if d.size else 1.0
        return bool(f >= p[1]), f"within {p[0]}: {f:.4f} (want {p[1]})"
    if k == "iou":
        a, b = ours != 0, ref != 0
        u = (a | b).sum()
        v = (a & b).sum() / u if u else 1.0
        return bool(v >= p[0]), f"iou {v:.4f} (want {p[0]})"
    if k == "cnt":
        n, m = len(ours), len(ref)
        return bool(abs(n - m) <= p[0] * max(m, 1)), f"count {n} vs {m}"
    if k == "pts":
        a, b = o.reshape(len(o), -1), r.reshape(len(r), -1)
        if len(b) == 0:
            return True, "no ref points"
        if len(a) == 0:
            return False, "no points"
        dist = np.sqrt(((b[:, None, :] - a[None, :, :]) ** 2).sum(-1)).min(1)
        f = (dist <= p[0]).mean()
        return bool(f >= p[1]), f"ref points matched within {p[0]}: {f:.4f} (want {p[1]})"
    raise ValueError("unknown cmp " + spec)


# ---- fixtures ---------------------------------------------------------------------------------------------
SHOT = os.path.expanduser("~/Projects/AMD/.work/")


def make_fixtures(d):
    """Inputs named by the case rows. hd* are 1080p crops of two real screenshots; the rest are synthetic."""
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(7)
    A, B = cv2.imread(SHOT + "shotA.png"), cv2.imread(SHOT + "shotB.png")
    if A is None or B is None:
        raise SystemExit("FAIL fixtures: need ~/Projects/AMD/.work/shotA.png and shotB.png")
    fx = {"hd": A[:, :1920], "hd2": B[:, :1920]}
    fx["hdg"] = cv2.cvtColor(fx["hd"], cv2.COLOR_BGR2GRAY)
    fx["hdg2"] = cv2.cvtColor(fx["hd2"], cv2.COLOR_BGR2GRAY)
    fx["sm"], fx["sm2"] = fx["hd"][300:570, 400:880].copy(), fx["hd2"][300:570, 400:880].copy()
    fx["smg"], fx["smg2"] = fx["hdg"][300:570, 400:880].copy(), fx["hdg2"][300:570, 400:880].copy()
    fx["odd"] = rng.integers(0, 256, (7, 13, 3), dtype=np.uint8)
    fx["odd2"] = rng.integers(0, 256, (7, 13, 3), dtype=np.uint8)
    fx["one"] = np.array([[[200, 0, 77]]], np.uint8)
    fx["one2"] = np.array([[[10, 255, 77]]], np.uint8)
    fx["g1"] = rng.integers(0, 256, (5, 9), dtype=np.uint8)
    fx["g2"] = rng.integers(0, 256, (5, 9), dtype=np.uint8)
    fx["i16"] = rng.integers(-32768, 32768, (6, 11, 2), dtype=np.int16)
    fx["i16b"] = rng.integers(-32768, 32768, (6, 11, 2), dtype=np.int16)
    fx["i32"] = rng.integers(-2**31, 2**31, (6, 11), dtype=np.int32)
    fx["i32b"] = rng.integers(-2**31, 2**31, (6, 11), dtype=np.int32)
    fx["f32"] = (rng.standard_normal((9, 17, 3)) * 300).astype(np.float32)
    fx["f32b"] = (rng.standard_normal((9, 17, 3)) * 300).astype(np.float32)
    fx["f64"] = rng.standard_normal((8, 5)) * 1e3
    fx["half"] = np.array([[-2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 254.5, 255.5, 300.0, -7.0]], np.float32)
    for n, a in fx.items():
        mcv.save(a, os.path.join(d, n + ".mcv"))


# ---- driver -----------------------------------------------------------------------------------------------
def outputs(res):
    return res if isinstance(res, (list, tuple)) else [res]


def run_one(opname, out, ins, kv):
    arrs = [mcv.load(p) for p in ins]
    reps = kv_i(kv, "reps", 1)
    best = 1e30
    for _ in range(reps):
        t = time.perf_counter()
        res = OPS[opname](arrs, kv)
        best = min(best, (time.perf_counter() - t) * 1e3)
    for n, a in enumerate(outputs(res)):
        mcv.save(np.asarray(a), out if n == 0 else f"{out}.{n}")
    if reps > 1:
        print("TIME", best)


def parse_row(line):
    left, cmp_ = line.split("=>")
    tok = left.split()
    cid, opn, rest = tok[0], tok[1], tok[2:]
    ins = [t for t in rest if "=" not in t]
    kv = dict(t.split("=", 1) for t in rest if "=" in t)
    return cid, opn, ins, kv, [c.strip() for c in cmp_.split(",")]


def rows(files):
    for f in files:
        for ln in open(f):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                yield f, parse_row(ln)


def fpath(n):
    return n if "/" in n else os.path.join(FIX, n + ".mcv")


def time_of(text):
    m = re.search(r"TIME ([0-9.e+-]+)", text)
    return float(m.group(1)) if m else None


def suite(files, bench):
    work = os.path.join(ROOT, ".work", "t")
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(ROOT, ".bin", "mojo-cv")
    npass = nfail = 0
    table = []
    for f, (cid, opn, ins, kv, cmps) in rows(files):
        paths = [fpath(n) for n in ins]
        kvs = [f"{k}={v}" for k, v in kv.items()]
        hd = any(n.startswith("hd") for n in ins)
        if bench and not hd:
            continue
        kvs_b = kvs + (["reps=5"] if bench else [])
        o, r = os.path.join(work, cid + ".ours"), os.path.join(work, cid + ".ref")
        for p in (o, r):
            for g in [p] + [f"{p}.{n}" for n in range(1, 6)]:
                if os.path.exists(g):
                    os.remove(g)
        try:
            tr = subprocess.run([sys.executable, "-I", __file__, opn, r, *paths, *kvs_b], capture_output=True, text=True)
            to = subprocess.run([exe, opn, o, *paths, *kvs_b], capture_output=True, text=True)
            msg, ok = "", True
            if tr.returncode:
                ok, msg = False, "oracle failed: " + tr.stderr.strip().splitlines()[-1]
            elif to.returncode:
                ok, msg = False, "ours failed: " + (to.stdout + to.stderr).strip()[-300:]
            else:
                for n, spec in enumerate(cmps):
                    sfx = "" if n == 0 else f".{n}"
                    if not os.path.exists(r + sfx) or not os.path.exists(o + sfx):
                        ok, msg = False, f"missing output {n}"
                        break
                    good, why = compare(mcv.load(o + sfx), mcv.load(r + sfx), spec)
                    msg += f"[{n}] {spec}: {why}  "
                    ok &= good
        except Exception as e:  # a harness bug must not read as a pass
            ok, msg = False, f"harness error: {e!r}"
        print(("PASS" if ok else "FAIL"), cid, "-", msg.strip(), flush=True)
        npass += ok
        nfail += not ok
        if bench and ok:
            table.append((opn, cid, time_of(to.stdout), time_of(tr.stdout)))
    print(f"rows: {npass + nfail}  pass: {npass}  fail: {nfail}")
    if bench:
        print("| op | row | ours ms | cv2 ms | ratio |\n|---|---|---|---|---|")
        for opn, cid, a, b in table:
            print(f"| {opn} | {cid} | {a:.2f} | {b:.2f} | {a / b:.2f} |" if a and b else f"| {opn} | {cid} | {a} | {b} | |")
    return nfail


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--suite":
        bench = "--bench" in a
        sys.exit(1 if suite([x for x in a[1:] if not x.startswith("--")], bench) else 0)
    if a and a[0] == "--fixtures":
        make_fixtures(a[1])
        sys.exit(0)
    run_one(a[0], a[1], [x for x in a[2:] if "=" not in x], dict(x.split("=", 1) for x in a[2:] if "=" in x))
