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


INTERP = [cv2.INTER_NEAREST, cv2.INTER_LINEAR, cv2.INTER_CUBIC, cv2.INTER_LANCZOS4]
BORDER = [cv2.BORDER_REFLECT_101, cv2.BORDER_REPLICATE, cv2.BORDER_CONSTANT]  # border=0 reflect101, 1 replicate, 2 constant


def kv_l(kv, k, d=None):
    return [float(x) for x in kv[k].split(",")] if k in kv else d
@op()
def resize(i, kv):
    h, w = i[0].shape[:2]
    return cv2.resize(i[0], (kv_i(kv, "w", w), kv_i(kv, "h", h)), interpolation=INTERP[kv_i(kv, "interp", 1)])
@op()
def warpAffine(i, kv):
    h, w = i[0].shape[:2]
    fl = INTERP[kv_i(kv, "interp", 1)] | (cv2.WARP_INVERSE_MAP if kv_i(kv, "inv", 0) else 0)
    return cv2.warpAffine(i[0], np.array(kv_l(kv, "M", [1, 0, 0, 0, 1, 0])).reshape(2, 3), (kv_i(kv, "w", w), kv_i(kv, "h", h)), flags=fl,
                          borderMode=BORDER[kv_i(kv, "border", 2)], borderValue=(kv_f(kv, "bval", 0.0),) * 4)
@op()
def remap(i, kv):
    return cv2.remap(i[0], i[1], i[2], INTERP[kv_i(kv, "interp", 1)], borderMode=BORDER[kv_i(kv, "border", 2)], borderValue=(kv_f(kv, "bval", 0.0),) * 4)
@op()
def blobFromImage(i, kv):
    h, w = i[0].shape[:2]
    b = cv2.dnn.blobFromImage(i[0], kv_f(kv, "scale", 1.0), (kv_i(kv, "w", w), kv_i(kv, "h", h)), tuple(kv_l(kv, "mean", [0, 0, 0])), bool(kv_i(kv, "swap", 0)), False)
    return b.reshape(-1, b.shape[3])


@op()
def connectedComponentsWithStats(i, kv):
    n, lab, st, cen = cv2.connectedComponentsWithStats(i[0], connectivity=kv_i(kv, "connectivity", 8), ltype=cv2.CV_32S)
    return [lab, st, cen]
@op()
def Canny(i, kv):
    return cv2.Canny(i[0], kv_f(kv, "t1", 100.0), kv_f(kv, "t2", 200.0), apertureSize=kv_i(kv, "aperture", 3), L2gradient=bool(kv_i(kv, "l2", 0)))
@op()
def findContours(i, kv):
    cs, _ = cv2.findContours(i[0], [cv2.RETR_EXTERNAL, cv2.RETR_LIST][kv_i(kv, "mode", 0)], [cv2.CHAIN_APPROX_NONE, cv2.CHAIN_APPROX_SIMPLE][kv_i(kv, "method", 0)])
    pts = np.concatenate([c.reshape(-1, 2) for c in cs]) if cs else np.zeros((0, 2), np.int32)
    return [pts.astype(np.int32), np.array([[len(c)] for c in cs], np.int32).reshape(-1, 1)]
@op()
def goodFeaturesToTrack(i, kv):
    r = cv2.goodFeaturesToTrack(i[0], kv_i(kv, "maxCorners", 100), kv_f(kv, "quality", 0.01), kv_f(kv, "minDist", 10.0), blockSize=kv_i(kv, "block", 3))
    return np.zeros((0, 2), np.float32) if r is None else r.reshape(-1, 2).astype(np.float32)
@op()
def line(i, kv):
    im = i[0].copy()
    c = tuple(kv_l(kv, "color", [255, 255, 255]))
    return cv2.line(im, (kv_i(kv, "x1", 0), kv_i(kv, "y1", 0)), (kv_i(kv, "x2", 0), kv_i(kv, "y2", 0)), c, 1)
@op()
def rectangle(i, kv):
    im = i[0].copy()
    c = tuple(kv_l(kv, "color", [255, 255, 255]))
    return cv2.rectangle(im, (kv_i(kv, "x1", 0), kv_i(kv, "y1", 0)), (kv_i(kv, "x2", 0), kv_i(kv, "y2", 0)), c, kv_i(kv, "thick", 1))


@op()
def bfmatch(i, kv):
    m = cv2.BFMatcher(cv2.NORM_HAMMING).match(i[0], i[1])
    return np.array([[x.trainIdx, int(x.distance)] for x in m], np.int32).reshape(-1, 2)
@op()
def knnmatch(i, kv):
    k = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(i[0], i[1], k=2)
    tab = np.array([[m[0].trainIdx, int(m[0].distance), m[1].trainIdx, int(m[1].distance)] for m in k], np.int32).reshape(-1, 4)
    r = kv_f(kv, "ratio", 0.75)
    good = np.array([[q, m[0].trainIdx, int(m[0].distance)] for q, m in enumerate(k) if m[0].distance < r * m[1].distance], np.int32).reshape(-1, 3)
    return [tab, good]


@op()
def cornerSubPix(i, kv):
    w = kv_i(kv, "win", 5)
    z = kv_i(kv, "zero", -1)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_COUNT, kv_i(kv, "maxIter", 30), kv_f(kv, "eps", 0.01))
    return cv2.cornerSubPix(i[0], i[1].reshape(-1, 1, 2).copy(), (w, w), (z, z), crit).reshape(-1, 2)
@op()
def calcOpticalFlowPyrLK(i, kv):
    w = kv_i(kv, "win", 21)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_COUNT, kv_i(kv, "maxCount", 30), kv_f(kv, "eps", 0.01))
    nxt, st, err = cv2.calcOpticalFlowPyrLK(i[0], i[1], i[2].reshape(-1, 1, 2).copy(), None, winSize=(w, w), maxLevel=kv_i(kv, "maxLevel", 3), criteria=crit)
    return [nxt.reshape(-1, 2), st.reshape(-1, 1), err.reshape(-1, 1)]


@op()
def calcOpticalFlowFarneback(i, kv):
    return cv2.calcOpticalFlowFarneback(i[0], i[1], None, kv_f(kv, "pyrScale", 0.5), kv_i(kv, "levels", 3), kv_i(kv, "winsize", 15),
                                        kv_i(kv, "iters", 3), kv_i(kv, "polyN", 5), kv_f(kv, "polySigma", 1.2), 0)


# ---- calib3d (all arrays float64; points are (n, 2) or (n, 3)) --------------------------------------------
@op()
def Rodrigues(i, kv): return cv2.Rodrigues(i[0])[0]
@op()
def projectPoints(i, kv): return cv2.projectPoints(i[0], i[1], i[2], i[3], i[4])[0].reshape(-1, 2)
@op()
def fisheye_projectPoints(i, kv): return cv2.fisheye.projectPoints(i[0].reshape(-1, 1, 3), i[1], i[2], i[3], i[4])[0].reshape(-1, 2)
@op()
def undistortPoints(i, kv):
    R = i[3] if len(i) > 3 else None
    P = i[4] if len(i) > 4 else None
    return cv2.undistortPoints(i[0].reshape(-1, 1, 2), i[1], i[2], R=R, P=P).reshape(-1, 2)
@op()
def fisheye_undistortPoints(i, kv):
    R = i[3] if len(i) > 3 else None
    P = i[4] if len(i) > 4 else None
    return cv2.fisheye.undistortPoints(i[0].reshape(-1, 1, 2), i[1], i[2], R=R, P=P).reshape(-1, 2)
@op()
def initUndistortRectifyMap(i, kv):
    return list(cv2.initUndistortRectifyMap(i[0], i[1], i[2], i[3], (kv_i(kv, "w", 640), kv_i(kv, "h", 480)), cv2.CV_32FC1))
@op()
def fisheye_initUndistortRectifyMap(i, kv):
    return list(cv2.fisheye.initUndistortRectifyMap(i[0], i[1], i[2], i[3], (kv_i(kv, "w", 640), kv_i(kv, "h", 480)), cv2.CV_32FC1))


@op()
def estimateAffine2D(i, kv):
    m, inl = cv2.estimateAffine2D(i[0], i[1], method=cv2.RANSAC, ransacReprojThreshold=kv_f(kv, "thresh", 3.0), maxIters=kv_i(kv, "maxIters", 2000), confidence=kv_f(kv, "conf", 0.99))
    return [m, inl.reshape(-1, 1).astype(np.uint8)]
@op()
def solvePnP(i, kv):
    ok, r, t = cv2.solvePnP(i[0], i[1], i[2], i[3] if i[3].size else None, flags=cv2.SOLVEPNP_ITERATIVE)
    return [r.reshape(3, 1), t.reshape(3, 1)]
@op()
def solvePnPRansac(i, kv):
    ok, r, t, inl = cv2.solvePnPRansac(i[0], i[1], i[2], i[3] if i[3].size else None, iterationsCount=kv_i(kv, "iters", 100),
                                      reprojectionError=kv_f(kv, "thresh", 8.0), confidence=kv_f(kv, "conf", 0.99), flags=cv2.SOLVEPNP_ITERATIVE)
    return [r.reshape(3, 1), t.reshape(3, 1), np.sort(inl.reshape(-1, 1).astype(np.int32), axis=0)]
@op()
def findEssentialMat(i, kv):
    E, m = cv2.findEssentialMat(i[0], i[1], i[2], method=cv2.RANSAC, prob=kv_f(kv, "prob", 0.999), threshold=kv_f(kv, "thresh", 1.0))
    E = E[:3] / np.linalg.norm(E[:3])
    if E.flat[np.argmax(np.abs(E))] < 0:
        E = -E
    return [E, m.reshape(-1, 1).astype(np.uint8)]
@op()
def recoverPose(i, kv):
    mask = i[4].copy() if len(i) > 4 else None
    n, R, t, _ = cv2.recoverPose(i[0], i[1], i[2], i[3], mask=mask)
    return [R, t.reshape(3, 1), np.array([[n]], np.int32)]
@op()
def stereoRectify(i, kv):
    R1, R2, P1, P2, Q, _, _ = cv2.stereoRectify(i[0], i[1], i[2], i[3], (kv_i(kv, "w", 640), kv_i(kv, "h", 480)), i[4], i[5],
                                                 flags=cv2.CALIB_ZERO_DISPARITY if kv_i(kv, "zero", 1) else 0)
    return [R1, R2, P1, P2, Q]


@op()
def StereoSGBM(i, kv):
    b = kv_i(kv, "block", 5)
    sg = cv2.StereoSGBM_create(minDisparity=kv_i(kv, "minDisp", 0), numDisparities=kv_i(kv, "numDisp", 32), blockSize=b, P1=kv_i(kv, "P1", 8 * b * b),
                               P2=kv_i(kv, "P2", 32 * b * b), disp12MaxDiff=kv_i(kv, "lrMax", 0), uniquenessRatio=kv_i(kv, "uniq", 0))
    return sg.compute(i[0], i[1])


@op()
def findChessboardCorners(i, kv):
    ok, c = cv2.findChessboardCorners(i[0], (kv_i(kv, "cols", 9), kv_i(kv, "rows", 6)))
    return c.reshape(-1, 2).astype(np.float32) if ok else np.zeros((0, 2), np.float32)


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
    fx["bin"] = (fx["smg"] < 128).astype(np.uint8) * 255
    fx["binhd"] = (fx["hdg"] < 128).astype(np.uint8) * 255
    shapes = np.zeros((60, 80), np.uint8)
    cv2.rectangle(shapes, (5, 5), (30, 30), 255, -1)
    cv2.rectangle(shapes, (12, 12), (22, 22), 0, -1)
    cv2.circle(shapes, (55, 30), 15, 255, -1)
    cv2.circle(shapes, (55, 30), 6, 0, -1)
    cv2.line(shapes, (3, 50), (70, 57), 255, 1)
    shapes[40, 40] = 255
    shapes[0, 0:5] = 255
    fx["shapes"] = shapes
    fx["blank"] = np.zeros((9, 11), np.uint8)
    fx["full"] = np.full((9, 11), 255, np.uint8)
    M = np.array([[1, 0, 2.6], [0, 1, 1.7]], np.float64)
    hm = cv2.warpAffine(fx["hdg"], M, (1920, 1080), flags=cv2.INTER_LINEAR)
    fx["lk_prev"], fx["lk_next"] = fx["smg"].copy(), hm[300:570, 400:880].copy()
    gp = cv2.goodFeaturesToTrack(fx["smg"], 120, 0.05, 10).reshape(-1, 2).astype(np.float32)
    fx["lk_pts"] = np.vstack([gp, np.array([[3, 3], [476, 266]], np.float32)])
    fx["sp_pts"] = gp[:80] + rng.uniform(-1.2, 1.2, (80, 2)).astype(np.float32)
    da = rng.integers(0, 256, (200, 32), dtype=np.uint8)
    db = rng.integers(0, 256, (300, 32), dtype=np.uint8)
    db[:150] = da[:150] ^ (rng.random((150, 32)) < 0.02).astype(np.uint8)  # 150 near copies of the first 150 queries
    fx["desc_a"], fx["desc_b"] = da, db
    fx["desc_one"] = da[:1].copy()
    # calib3d inputs
    fx["K"] = np.array([[800, 0, 320], [0, 790, 240], [0, 0, 1.0]])
    fx["Kb"] = np.array([[1000, 0, 500], [0, 1000, 400], [0, 0, 1.0]])
    fx["d4"] = np.array([[-0.2], [0.05], [0.001], [-0.002]])
    fx["d5"] = np.array([[-0.25], [0.08], [0.001], [-0.002], [-0.02]])
    fx["d8"] = np.array([[-0.2], [0.05], [0.001], [-0.002], [0.01], [0.1], [-0.05], [0.02]])
    fx["d12"] = np.array([[-0.2], [0.05], [0.001], [-0.002], [0.01], [0.1], [-0.05], [0.02], [0.001], [-0.0005], [0.0008], [0.0002]])
    fx["dz"] = np.zeros((5, 1))
    fx["dfe"] = np.array([[-0.05], [0.01], [-0.002], [0.0003]])
    fx["obj3"] = np.column_stack([rng.uniform(-1, 1, 30), rng.uniform(-1, 1, 30), rng.uniform(3, 6, 30)])
    fx["rv"] = np.array([[0.1], [-0.2], [0.05]])
    fx["tv"] = np.array([[0.1], [-0.05], [0.3]])
    fx["rv0"] = np.zeros((3, 1))
    fx["pix"] = np.vstack([rng.uniform(0, 640, 40), rng.uniform(0, 480, 40)]).T
    fx["Rr"] = cv2.Rodrigues(np.array([0.02, -0.03, 0.01]))[0]
    fx["Pn"] = np.array([[700, 0, 330, 0], [0, 700, 250, 0], [0, 0, 1, 0.0]])
    fx["rod_v"] = np.array([[0.3], [-0.7], [0.5]])
    fx["rod_v0"] = np.array([[0.0], [0.0], [0.0]])
    fx["rod_m"] = cv2.Rodrigues(np.array([0.3, -0.7, 0.5]))[0]
    fx["rod_mpi"] = cv2.Rodrigues(np.array([2.2214414691, 2.2214414691, 0.0]))[0]
    fx["rod_mid"] = np.eye(3)
    # geometry fixtures: two views of a point cloud, 3D-2D correspondences, affine pairs
    Kc = fx["K"]
    cloud = np.column_stack([rng.uniform(-1.5, 1.5, 60), rng.uniform(-1, 1, 60), rng.uniform(4, 9, 60)])
    rv2, tv2 = np.array([0.05, -0.12, 0.03]), np.array([[-0.8], [0.05], [0.1]])
    tv2 = tv2 / np.linalg.norm(tv2)
    q1 = cv2.projectPoints(cloud, np.zeros(3), np.zeros(3), Kc, None)[0].reshape(-1, 2)
    q2 = cv2.projectPoints(cloud, rv2, tv2, Kc, None)[0].reshape(-1, 2)
    q2n = q2 + rng.normal(0, 0.3, q2.shape)
    for q in (q2, q2n):
        q[:12] = rng.uniform(0, 640, (12, 2))  # gross outliers
    fx["ess_p1"], fx["ess_p2"], fx["ess_p2n"] = q1, q2, q2n
    tn = tv2.reshape(3)
    fx["pose_E"] = np.array([[0, -tn[2], tn[1]], [tn[2], 0, -tn[0]], [-tn[1], tn[0], 0]]) @ cv2.Rodrigues(rv2)[0]
    fx["pose_mask"] = np.concatenate([np.zeros(12), np.ones(48)]).reshape(-1, 1).astype(np.uint8)
    fx["pnp_obj"] = np.column_stack([rng.uniform(-1, 1, 40), rng.uniform(-0.8, 0.8, 40), rng.uniform(-0.5, 0.5, 40)])
    fx["pnp_obj_pl"] = np.column_stack([rng.uniform(-1, 1, 12), rng.uniform(-0.8, 0.8, 12), np.zeros(12)])
    rvp, tvp = np.array([0.2, -0.3, 0.1]), np.array([0.1, -0.2, 5.0])
    fx["pnp_img"] = cv2.projectPoints(fx["pnp_obj"], rvp, tvp, Kc, fx["d4"])[0].reshape(-1, 2)
    fx["pnp_img_pl"] = cv2.projectPoints(fx["pnp_obj_pl"], rvp, tvp, Kc, fx["d4"])[0].reshape(-1, 2)
    out = fx["pnp_img"].copy()
    out[:12] = rng.uniform(0, 640, (12, 2))
    fx["pnp_img_out"] = out
    Af = np.array([[0.9, -0.3, 12.0], [0.25, 1.1, -7.0]])
    pa = rng.uniform(0, 300, (80, 2))
    pb = pa @ Af[:, :2].T + Af[:, 2]
    pb[:16] = rng.uniform(0, 300, (16, 2))
    fx["aff_from"], fx["aff_to"] = pa, pb
    fx["Rst"] = cv2.Rodrigues(np.array([0.01, -0.02, 0.005]))[0]
    fx["Tst"] = np.array([[-0.12], [0.003], [0.002]])
    fx["K2"] = np.array([[820, 0, 315], [0, 830, 245], [0, 0, 1.0]])
    fx["dst1"] = np.array([[-0.2], [0.05], [0], [0], [0]])
    fx["dst2"] = np.array([[-0.1], [0.02], [0], [0], [0]])
    H, W = 120, 200
    base = cv2.GaussianBlur(rng.integers(0, 256, (H, W + 60), dtype=np.uint8), (0, 0), 1.2)
    dm = np.full((H, W), 6, np.int32)
    dm[30:90, 70:150] = 14
    SL = base[:, 30:30 + W].copy()
    SR = np.zeros((H, W), np.uint8)
    for yy in range(H):
        for xx in range(W):
            xr_ = xx - dm[yy, xx]
            if 0 <= xr_ < W:
                SR[yy, xr_] = SL[yy, xx]
    fx["st_l"], fx["st_r"] = SL, SR
    def board(cols_, rows_, sq=40, margin=60):
        b = np.zeros(((rows_ + 1) * sq, (cols_ + 1) * sq), np.uint8)
        for r_ in range(rows_ + 1):
            for c_ in range(cols_ + 1):
                if (r_ + c_) % 2 == 0:
                    b[r_ * sq:(r_ + 1) * sq, c_ * sq:(c_ + 1) * sq] = 255
        big = np.full((b.shape[0] + 2 * margin, b.shape[1] + 2 * margin), 200, np.uint8)
        big[margin:-margin, margin:-margin] = b
        return big
    for nm, (cc_, rr_, Mh) in {"cb_a": (9, 6, [[0.9, 0.15, 40], [-0.1, 0.95, 30], [0.0002, 0.0001, 1]]),
                              "cb_b": (7, 5, [[0.6, -0.5, 250], [0.5, 0.6, 20], [0.0003, -0.0002, 1]]),
                              "cb_c": (6, 4, [[1.2, 0.0, 30], [0.0, 1.2, 40], [0.0, 0.0, 1]])}.items():
        fx[nm] = cv2.GaussianBlur(cv2.warpPerspective(board(cc_, rr_), np.array(Mh), (640, 480), borderValue=200), (3, 3), 0)
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
    for nm, (hh, ww) in {"": (1080, 1920), "s": (270, 480)}.items():
        yy, xx = np.mgrid[0:hh, 0:ww].astype(np.float32)
        fx["mapx" + nm] = (xx + 12 * np.sin(yy / 17) + 0.37).astype(np.float32)
        fx["mapy" + nm] = (yy + 9 * np.cos(xx / 23) - 0.21).astype(np.float32)
    fx["mapxo"] = rng.uniform(-3, 16, (7, 13)).astype(np.float32)
    fx["mapyo"] = rng.uniform(-3, 10, (7, 13)).astype(np.float32)
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
