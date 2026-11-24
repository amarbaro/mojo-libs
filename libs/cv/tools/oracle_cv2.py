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
    ty = kv_i(kv, "type", 0) | (cv2.THRESH_OTSU if kv_i(kv, "otsu", 0) else 0) | (cv2.THRESH_TRIANGLE if kv_i(kv, "tri", 0) else 0)
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
         "bgr2hsv": cv2.COLOR_BGR2HSV, "hsv2bgr": cv2.COLOR_HSV2BGR, "bgr2ycrcb": cv2.COLOR_BGR2YCrCb, "ycrcb2bgr": cv2.COLOR_YCrCb2BGR,
         "bgr2lab": cv2.COLOR_BGR2Lab, "lab2bgr": cv2.COLOR_Lab2BGR, "bgr2luv": cv2.COLOR_BGR2Luv, "luv2bgr": cv2.COLOR_Luv2BGR}
    return cv2.cvtColor(i[0], c[kv["code"]])


INTERP = [cv2.INTER_NEAREST, cv2.INTER_LINEAR, cv2.INTER_CUBIC, cv2.INTER_LANCZOS4, cv2.INTER_AREA]
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
    cs, hi = cv2.findContours(i[0], [cv2.RETR_EXTERNAL, cv2.RETR_LIST, cv2.RETR_CCOMP, cv2.RETR_TREE][kv_i(kv, "mode", 0)], [cv2.CHAIN_APPROX_NONE, cv2.CHAIN_APPROX_SIMPLE][kv_i(kv, "method", 0)])
    pts = np.concatenate([c.reshape(-1, 2) for c in cs]) if cs else np.zeros((0, 2), np.int32)
    hier = np.zeros((0, 4), np.int32) if hi is None else hi.reshape(-1, 4).astype(np.int32)
    return [pts.astype(np.int32), np.array([[len(c)] for c in cs], np.int32).reshape(-1, 1), hier]
@op()
def goodFeaturesToTrack(i, kv):
    r = cv2.goodFeaturesToTrack(i[0], kv_i(kv, "maxCorners", 100), kv_f(kv, "quality", 0.01), kv_f(kv, "minDist", 10.0), blockSize=kv_i(kv, "block", 3), useHarrisDetector=bool(kv_i(kv, "harris", 0)), k=kv_f(kv, "k", 0.04))
    return np.zeros((0, 2), np.float32) if r is None else r.reshape(-1, 2).astype(np.float32)
@op()
def line(i, kv):
    im = i[0].copy()
    c = tuple(kv_l(kv, "color", [255, 255, 255]))
    return cv2.line(im, (kv_i(kv, "x1", 0), kv_i(kv, "y1", 0)), (kv_i(kv, "x2", 0), kv_i(kv, "y2", 0)), c, kv_i(kv, "thick", 1))
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
    flag = cv2.SOLVEPNP_EPNP if kv_i(kv, "epnp", 0) else cv2.SOLVEPNP_ITERATIVE
    ok, r, t = cv2.solvePnP(i[0], i[1], i[2], i[3] if i[3].size else None, flags=flag)
    if kv_i(kv, "epnp", 0):
        r, t = cv2.solvePnPRefineLM(i[0], i[1], i[2], i[3], r, t)
    return [r.reshape(3, 1), t.reshape(3, 1)]
@op()
def solvePnPRansac(i, kv):
    ok, r, t, inl = cv2.solvePnPRansac(i[0], i[1], i[2], i[3] if i[3].size else None, iterationsCount=kv_i(kv, "iters", 100),
                                      reprojectionError=kv_f(kv, "thresh", 8.0), confidence=kv_f(kv, "conf", 0.99), flags=cv2.SOLVEPNP_ITERATIVE)
    return [r.reshape(3, 1), t.reshape(3, 1), np.sort(inl.reshape(-1, 1).astype(np.int32), axis=0)]
@op()
def findEssentialMat(i, kv):
    E, m = cv2.findEssentialMat(i[0], i[1], i[2], method=cv2.RANSAC, prob=kv_f(kv, "prob", 0.999), threshold=kv_f(kv, "thresh", 1.0))
    if len(i[0]) == 5:
        models = E.reshape(-1, 3, 3)
        models = models / np.linalg.norm(models, axis=(1, 2))[:, None, None]
        for e in models:
            if e.flat[np.argmax(np.abs(e))] < 0:
                e *= -1
        return [models[np.argsort(models[:, 0, 0])].reshape(-1, 3), m.reshape(-1, 1).astype(np.uint8)]
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
                                                 flags=cv2.CALIB_ZERO_DISPARITY if kv_i(kv, "zero", 1) else 0, alpha=kv_f(kv, "alpha", -1.0))
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


@op()
def aruco_detect(i, kv):
    det = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50), cv2.aruco.DetectorParameters())
    corners, ids, _ = det.detectMarkers(i[0])
    if ids is None:
        return [np.zeros((0, 1), np.int32), np.zeros((0, 2), np.float32)]
    o = np.argsort(ids.ravel())
    return [ids.reshape(-1, 1)[o].astype(np.int32), np.concatenate([corners[k].reshape(4, 2) for k in o]).astype(np.float32)]


@op()
def ORB(i, kv):
    orb = cv2.ORB_create(nfeatures=kv_i(kv, "nfeatures", 500), fastThreshold=kv_i(kv, "fastThreshold", 20))
    kps, d = orb.detectAndCompute(i[0], None)
    if d is None:
        return np.zeros((0, 36), np.float32)
    rows = [[k.pt[0], k.pt[1], k.angle, k.octave] + list(r) for k, r in zip(kps, d)]
    return np.array(rows, np.float32)


PY4 = os.environ.get("MCV_PY4", os.path.join(ROOT, ".venv4", "bin", "python"))  # cv2 4.8.1 for the HOG rows, see scripts/ci.sh
HOG_OPS = ("HOGScores", "detectMultiScale", "groupRectangles")  # cv2 5.0 dropped HOGDescriptor: these run under cv2 4.8.1 (PY4)


def _hog(svm):
    h = cv2.HOGDescriptor()
    h.setSVMDetector(svm.reshape(-1, 1).astype(np.float32))
    return h
@op()
def HOGScores(i, kv):
    d = _hog(i[1]).compute(i[0], (8, 8), (0, 0)).reshape(-1, 3780)
    nx = (i[0].shape[1] - 64) // 8 + 1
    return (d @ i[1].ravel()[:3780] + i[1].ravel()[3780]).reshape(-1, nx).astype(np.float32)
@op()
def detectMultiScale(i, kv):
    r, _ = _hog(i[1]).detectMultiScale(i[0], hitThreshold=kv_f(kv, "hit", 0.0), winStride=(8, 8), padding=(0, 0), scale=kv_f(kv, "scale", 1.05), groupThreshold=kv_i(kv, "group", 2))
    return np.array(r, np.int32).reshape(-1, 4)


@op()
def groupRectangles(i, kv):
    r, _ = cv2.groupRectangles(i[0].reshape(-1, 4).tolist(), kv_i(kv, "thresh", 2), 0.2)
    return np.array(r, np.int32).reshape(-1, 4)


@op()
def grabCut(i, kv):
    r = [int(x) for x in kv_l(kv, "rect", [0, 0, i[0].shape[1], i[0].shape[0]])]
    mask = np.zeros(i[0].shape[:2], np.uint8)
    bgd, fgd = np.zeros((1, 65)), np.zeros((1, 65))
    cv2.grabCut(i[0], mask, tuple(r), bgd, fgd, kv_i(kv, "iters", 5), cv2.GC_INIT_WITH_RECT)
    return ((mask & 1) * 255).astype(np.uint8)


# ---- compare ----------------------------------------------------------------------------------------------
def compare(ours, ref, spec):
    if ours.shape != ref.shape and not spec.startswith(("orb", "pts", "cnt")):
        return False, f"shape {ours.shape} vs {ref.shape}"
    if ours.dtype != ref.dtype:
        return False, f"dtype {ours.dtype} vs {ref.dtype}"
    k, *p = spec.split(":")
    p = [float(x) for x in p]
    o, r = ours.astype(np.float64), ref.astype(np.float64)
    d = np.abs(o - r) if o.shape == r.shape else None
    if k == "exact":
        return bool((d == 0).all()), f"maxdiff {d.max() if d.size else 0}"
    if k == "max":
        return bool((d <= p[0]).all()), f"maxdiff {d.max() if d.size else 0} (tol {p[0]})"
    if k == "eqnan":  # eqnan:T NaN exactly where the oracle has NaN, within T elsewhere
        an, rn = np.isnan(o), np.isnan(r)
        ok = bool((an == rn).all()) and bool((np.abs(o[~rn] - r[~rn]) <= p[0]).all())
        return ok, f"nan at {int(an.sum())} of {int(rn.sum())} oracle NaN, others within {p[0]}"
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
    if k == "orb":  # orb:T:F:H rows are x, y, angle, octave, 32 descriptor bytes
        if len(ref) == 0:
            return True, "no ref keypoints"
        if len(ours) == 0:
            return False, "no keypoints"
        hits, ham = 0, []
        for rr in ref:
            same = ours[ours[:, 3] == rr[3]]
            if len(same) == 0:
                continue
            dist = np.hypot(same[:, 0] - rr[0], same[:, 1] - rr[1])
            j = dist.argmin()
            if dist[j] <= p[0]:
                hits += 1
                ham.append(int(np.unpackbits((same[j, 4:].astype(np.uint8) ^ rr[4:].astype(np.uint8))).sum()))
        f = hits / len(ref)
        mh = float(np.mean(ham)) if ham else 1e9
        return bool(f >= p[1] and mh <= p[2]), f"kp matched {f:.3f} (want {p[1]}), mean hamming {mh:.1f} (want <= {p[2]}), ours {len(ours)} ref {len(ref)}"
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


# ---- granulo (cv2 for the openings; numpy for GLCM and LBP, scikit-image definitions) ----------------------
@op()
def granulometry(i, kv):
    out = []
    for r in [int(x) for x in kv.get("radii", "0,1,2,4").split(",")]:
        if r <= 0:
            out.append(float(i[0].astype(np.float64).sum()))
        else:
            se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
            out.append(float(cv2.morphologyEx(i[0], cv2.MORPH_OPEN, se).astype(np.float64).sum()))
    return np.array([out], np.float64)
@op()
def glcm(i, kv):
    L, dx, dy = kv_i(kv, "levels", 16), kv_i(kv, "dx", 1), kv_i(kv, "dy", 0)
    q = (i[0].astype(np.int64) * L) // 256
    h, w = q.shape
    a = q[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)]
    b = q[max(0, -dy) + dy:h - max(0, dy) + dy, max(0, -dx) + dx:w - max(0, dx) + dx]
    m = np.zeros((L, L)); np.add.at(m, (a.ravel(), b.ravel()), 1); m = m + m.T; p = m / m.sum()
    I, J = np.indices((L, L)); d = I - J
    mu = (p * I).sum(); var = (p * (I - mu) ** 2).sum(); cov = (p * (I - mu) * (J - mu)).sum()
    return np.array([[(p * d * d).sum(), (p * abs(d)).sum(), (p / (1 + d * d)).sum(), np.sqrt((p * p).sum()), cov / var if var > 0 else 1.0]])
@op()
def lbpHist(i, kv):
    g = i[0].astype(np.int64); c = g[1:-1, 1:-1]; code = np.zeros_like(c)
    for k, (dy, dx) in enumerate([(-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1)]):
        code |= (g[1 + dy:g.shape[0] - 1 + dy, 1 + dx:g.shape[1] - 1 + dx] >= c).astype(np.int64) << k
    return (np.bincount(code.ravel(), minlength=256) / code.size)[None, :].astype(np.float64)
@op()
def resizeMmpx(i, kv):
    f = kv_f(kv, "mmpx_in", 1.0) / kv_f(kv, "mmpx_out", 1.0)
    h, w = i[0].shape[:2]
    return cv2.resize(i[0], (max(1, int(w * f + 0.5)), max(1, int(h * f + 0.5))), interpolation=cv2.INTER_AREA if f < 1 else cv2.INTER_LINEAR)


SIEVES = [0.002, 0.0063, 0.02, 0.063, 0.2, 0.63, 2.0, 6.3, 20.0, 63.0, 200.0]
def _open_sum(g, r):
    if r <= 0:
        return float(g.astype(np.float64).sum())
    se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
    return float(cv2.morphologyEx(g, cv2.MORPH_OPEN, se).astype(np.float64).sum())
@op()
def granulometryMm(i, kv):
    ppm, g = kv_f(kv, "ppm", 1.0), i[0]; out = []
    for d in SIEVES:
        r = int(d * ppm / 2 + 0.5)
        if r < 1: out.append(-1.0); continue
        if 2 * r + 1 > min(g.shape[:2]) // 2: out.append(-2.0); continue
        se = np.ones((2 * r + 1, 2 * r + 1), np.uint8)
        out.append(100.0 * (1 - cv2.morphologyEx(g, cv2.MORPH_OPEN, se).astype(np.float64).mean() / g.astype(np.float64).mean()))
    return np.array([out])
@op()
def tophat(i, kv):
    k = kv_i(kv, "ksize", 15)
    return cv2.morphologyEx(i[0], cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
def _tile_var(v, t):
    h, w = v.shape[0] // t, v.shape[1] // t
    b = v[:h * t, :w * t].reshape(h, t, w, t).astype(np.float64)
    return (b * b).mean(axis=(1, 3)) - b.mean(axis=(1, 3)) ** 2
@op()
def smoothFraction(i, kv):
    m = _tile_var(i[0], kv_i(kv, "tile", 16))
    return np.array([[float((m < kv_f(kv, "thr", 4.0)).mean())]])
@op()
def sharpMap(i, kv):
    return _tile_var(cv2.Laplacian(i[0], cv2.CV_64F, ksize=1), kv_i(kv, "tile", 64))
@op()
def autocorr(i, kv):
    g = i[0].astype(np.float64); out = []
    for L in [int(x) for x in kv.get("lags", "1,2,4,8").split(",")]:
        rs = [np.corrcoef(g[:, :g.shape[1] - L].ravel(), g[:, L:].ravel())[0, 1], np.corrcoef(g[:g.shape[0] - L].ravel(), g[L:].ravel())[0, 1]]
        out.append(sum(rs) / 2)
    return np.array([out])
@op()
def waveletEnergy(i, kv):
    n = kv_i(kv, "levels", 5); g = i[0].astype(np.float64)
    a = g[:(g.shape[0] >> n) << n, :(g.shape[1] >> n) << n]; e = []
    for _ in range(n):
        p00, p01, p10, p11 = a[0::2, 0::2], a[0::2, 1::2], a[1::2, 0::2], a[1::2, 1::2]
        e.append((((p00 - p01 + p10 - p11) / 2) ** 2 + ((p00 + p01 - p10 - p11) / 2) ** 2 + ((p00 - p01 - p10 + p11) / 2) ** 2).sum())
        a = (p00 + p01 + p10 + p11) / 2
    e = np.array(e); return (e / e.sum())[None, :]
def _rim(v):
    n = len(v); m = np.sort(v[n // 4:3 * n // 4 + 1])[len(v[n // 4:3 * n // 4 + 1]) // 2]
    lo, hi, run = 0.55 * m, 0.75 * m, max(3, n // 333)
    i = 0
    while i < n and v[i] < lo: i += 1
    a = -1
    if i >= run:
        while i < n and v[i] < hi: i += 1
        a = i
    j = n - 1
    while j >= 0 and v[j] < lo: j -= 1
    b = -1
    if n - 1 - j >= run:
        while j >= 0 and v[j] < hi: j -= 1
        b = j
    return a, b
@op()
def trayRim(i, kv):
    g = i[0].astype(np.float64); l, r = _rim(g.sum(axis=0)); t, b = _rim(g.sum(axis=1))
    return np.array([[l, r, t, b, r - l if l >= 0 and r >= 0 else -1, b - t if t >= 0 and b >= 0 else -1]], np.float64)
@op()
def trayCrop(i, kv):
    g, m = i[0], kv_i(kv, "margin", 8)
    gg = g if g.ndim == 2 else np.rint(g.astype(np.float64).mean(axis=2)).astype(np.uint8)
    l, r, t, b, _, _ = trayRim([gg], kv)[0].astype(int)
    x0 = l + m if l >= 0 else 0; x1 = r - m if r >= 0 else g.shape[1] - 1
    y0 = t + m if t >= 0 else 0; y1 = b - m if b >= 0 else g.shape[0] - 1
    return g.copy() if x1 <= x0 or y1 <= y0 else g[y0:y1 + 1, x0:x1 + 1].copy()
def _reconstruct(marker, mask):
    k = np.ones((3, 3), np.uint8); j = marker.copy()
    while True:
        n = np.minimum(cv2.dilate(j, k), mask)
        if np.array_equal(n, j): return j
        j = n
@op()
def granulometryRec(i, kv):
    out = []
    for r in [int(x) for x in kv.get("radii", "1,2,4,8").split(",")]:
        if r <= 0: out.append(float(i[0].astype(np.float64).sum())); continue
        se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
        out.append(float(_reconstruct(cv2.erode(i[0], se), i[0]).astype(np.float64).sum()))
    return np.array([out])


# ---- stockcheck (cv2 / numpy on the same definitions: interior pixels, integer sums, one formula per number) ---
def _interior(f): return f[1:-1, 1:-1].astype(np.int64)
def _lap(g): return _interior(cv2.Laplacian(g, cv2.CV_64F, ksize=1))
def _sobel(g, dx, dy): return _interior(cv2.Sobel(g, cv2.CV_64F, dx, dy, ksize=3))


@op()
def sharpness(i, kv):
    g, t, thr = i[0], kv_i(kv, "tile", 32), kv_f(kv, "thr", 10.0)
    L = _lap(g)
    n = L.size
    ty, tx = (g.shape[0] - 2) // t, (g.shape[1] - 2) // t
    T = L[:ty * t, :tx * t].reshape(ty, t, tx, t).transpose(0, 2, 1, 3).reshape(ty, tx, -1)
    s1, s2 = T.sum(-1), (T * T).sum(-1)
    tv = (t * t * s2 - s1 * s1) / float(t * t * t * t)
    gx, gy = _sobel(g, 1, 0), _sobel(g, 0, 1)
    return np.array([[float(np.var(L.astype(np.float64))), float((gx * gx + gy * gy).sum()) / n, float((tv < thr).mean())]])


@op()
def noiseEst(i, kv):
    g = i[0].astype(np.int64)
    R, C = g.shape
    v = (g[:-2, :-2] - 2 * g[:-2, 1:-1] + g[:-2, 2:] - 2 * g[1:-1, :-2] + 4 * g[1:-1, 1:-1] - 2 * g[1:-1, 2:]
         + g[2:, :-2] - 2 * g[2:, 1:-1] + g[2:, 2:])
    d = np.abs(g[:, 1:] - g[:, :-1]).sum() + np.abs(g[1:] - g[:-1]).sum()
    return np.array([[np.sqrt(np.pi / 2) * float(np.abs(v).sum()) / (6.0 * (R - 2) * (C - 2)), float(d) / (R * (C - 1) + (R - 1) * C)]])


@op()
def blockiness(i, kv):
    g = i[0].astype(np.int64)
    eh, ev = np.abs(g[:, 1:] - g[:, :-1]), np.abs(g[1:] - g[:-1])
    mh, mv = (np.arange(g.shape[1] - 1) % 8) == 7, (np.arange(g.shape[0] - 1) % 8) == 7
    bh, nh = eh[:, mh].sum() / eh[:, mh].size, eh[:, ~mh].sum() / eh[:, ~mh].size
    bv, nv = ev[mv].sum() / ev[mv].size, ev[~mv].sum() / ev[~mv].size
    return np.array([[bh, nh, bv, nv, (bh + bv) / (nh + nv) if nh + nv > 0 else np.nan]])


@op()
def clipping(i, kv):
    g, lo, hi = i[0], kv_i(kv, "lo", 3), kv_i(kv, "hi", 252)
    h = np.bincount(g.ravel(), minlength=256).astype(np.int64)
    n = float(g.size)
    v = np.arange(256, dtype=np.int64)
    c = np.cumsum(h)
    m = float((v * h).sum()) / n
    return np.array([[h[:lo + 1].sum() / n, h[hi:].sum() / n, float(np.argmax(c >= int(np.ceil(0.01 * n)))),
                      float(np.argmax(c >= int(np.ceil(0.99 * n)))), m, np.sqrt(float((v * v * h).sum()) / n - m * m)]])


@op()
def colorCast(i, kv):
    a = i[0]
    n = float(a.shape[0] * a.shape[1])
    m = [a[:, :, k].astype(np.int64).sum() / n for k in range(3)]
    return np.array([[*m, m[2] - m[1], m[0] - (m[2] + m[1]) / 2.0]])


@op()
def banding(i, kv):
    g, t, bstd, brange = i[0], kv_i(kv, "btile", 16), kv_f(kv, "bstd", 6.0), kv_i(kv, "brange", 3)
    ty, tx = g.shape[0] // t, g.shape[1] // t
    T = g[:ty * t, :tx * t].astype(np.int64).reshape(ty, t, tx, t).transpose(0, 2, 1, 3)
    s1, s2 = T.sum((2, 3)), (T * T).sum((2, 3))
    smooth = ((T.max((2, 3)) - T.min((2, 3))) >= brange) & ~((t * t * s2 - s1 * s1).astype(np.float64) > bstd * bstd * float(t * t * t * t))
    S = T[smooth]
    dh, dv = np.abs(S[:, :, 1:] - S[:, :, :-1]), np.abs(S[:, 1:, :] - S[:, :-1, :])
    eq, jump = (dh == 0).sum() + (dv == 0).sum(), (dh >= 2).sum() + (dv >= 2).sum()
    pairs = dh.size + dv.size
    neq = pairs - eq
    return np.array([[smooth.mean(), eq / pairs if pairs else np.nan, jump / neq if neq else np.nan, float(smooth.sum())]])


@op()
def hazeBand(i, kv):
    g = i[0]
    R, C = g.shape
    gx, gy = _sobel(g, 1, 0), _sobel(g, 0, 1)
    E = gx * gx + gy * gy
    out = []
    for ax, idx in ((0, np.arange(1, C - 1) * 4 // C), (1, np.arange(1, R - 1) * 4 // R)):
        c = np.array([E[:, idx == s].sum() / E[:, idx == s].size if ax == 0 else E[idx == s].sum() / E[idx == s].size for s in range(4)])
        s = np.sort(c)
        med = (s[1] + s[2]) / 2.0
        out += [c.min() / med if med > 0 else np.nan, float(np.argmin(c))]
    return np.array([out])


def _cells(g, gh, gw):
    I = np.zeros((g.shape[0] + 1, g.shape[1] + 1), np.int64)
    I[1:, 1:] = g.astype(np.int64).cumsum(0).cumsum(1)
    ys = [k * g.shape[0] // gh for k in range(gh + 1)]
    xs = [k * g.shape[1] // gw for k in range(gw + 1)]
    return np.array([[(I[ys[a + 1], xs[b + 1]] - I[ys[a], xs[b + 1]] - I[ys[a + 1], xs[b]] + I[ys[a], xs[b]]) / float((ys[a + 1] - ys[a]) * (xs[b + 1] - xs[b]))
                      for b in range(gw)] for a in range(gh)])


@op()
def hashes(i, kv):
    g = i[0]
    d = _cells(g, 8, 9)
    out = np.zeros((2, 64), np.uint8)
    out[0] = (d[:, 1:] > d[:, :-1]).ravel()
    q = np.ceil(cv2.dct(_cells(g, 32, 32))[:8, :8].ravel() * 1e6 - 0.5)
    out[1, :63] = q[1:] > np.sort(q[1:])[31]
    return out


@op()
def hamPairs(i, kv):
    b = i[0]
    d = (b[:, None, :] != b[None, :, :]).sum(-1)
    iu, ju = np.triu_indices(len(b), 1)
    k = d[iu, ju] <= kv_i(kv, "thr", 10)
    return np.stack([iu[k], ju[k], d[iu, ju][k]], 1).astype(np.int32).reshape(-1, 3)


@op()
def boxDown(i, kv):
    g, f = i[0], kv_i(kv, "f", 2)
    h, w = g.shape[0] // f, g.shape[1] // f
    s = g[:h * f, :w * f].astype(np.int64).reshape(h, f, w, f).sum((1, 3))
    return ((s + f * f // 2) // (f * f)).astype(np.uint8)


@op()
def stockMetrics(i, kv):
    a = i[0]
    g = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    asc = kv_i(kv, "ascale", 1536)
    f = max(1, (max(g.shape) + asc // 2) // asc)
    ga = boxDown([g], {"f": f}) if f > 1 else g  # sharpness, noise, clipping, banding, fog at the analysis scale
    return np.concatenate([sharpness([ga], kv), noiseEst([ga], kv), blockiness([g], kv), clipping([ga], kv), colorCast([a], kv), banding([ga], kv), hazeBand([ga], kv), clipRegion([ga], kv)], 1)


@op()
def hysteresis(i, kv):
    a, lo, hi = i[0], kv_i(kv, "lo", 100), kv_i(kv, "hi", 200)
    n, lab, st, _ = cv2.connectedComponentsWithStats((a > lo).astype(np.uint8), connectivity=kv_i(kv, "connectivity", 8))
    keep = np.zeros(n, bool)
    keep[1:] = st[1:, cv2.CC_STAT_AREA] >= kv_i(kv, "min_area", 1)
    seeded = np.zeros(n, bool)
    seeded[np.unique(lab[a > hi])] = True
    return ((keep & seeded)[lab] & (lab > 0)).astype(np.uint8) * 255


def _largest(mask):
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    if n < 2:
        return [0.0] * 4
    k = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
    R, C = mask.shape
    return [st[k, cv2.CC_STAT_AREA] / (R * C), st[k, cv2.CC_STAT_WIDTH] / C, st[k, cv2.CC_STAT_HEIGHT] / R, float(n - 1)]


@op()
def clipRegion(i, kv):
    g = i[0]
    return np.array([_largest(g >= kv_i(kv, "hi", 252)) + _largest(g <= kv_i(kv, "lo", 3))])


# ---- hyper (papers 2023-2026): cv2 where cv2 has the op, numpy definitions otherwise --------------------------
def _fit_affine(flow, use):
    h, w = flow.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    X = np.stack([(xx - (w - 1) / 2).ravel(), (yy - (h - 1) / 2).ravel(), np.ones(h * w)], 1)
    f = flow.reshape(-1, 2).astype(np.float64)
    u = use.ravel()
    p = np.linalg.lstsq(X[u], f[u], rcond=None)[0]  # (3, 2): columns are the u and v parameters
    return X, f, p


@op()
def flowDecomp(i, kv):
    flow = i[0]
    base = (i[1] != 0) if len(i) > 1 else np.ones(flow.shape[:2], bool)
    use = base.copy()
    for it in range(kv_i(kv, "iters", 1)):
        X, f, p = _fit_affine(flow, use)
        res = f - X @ p
        use = base & (np.hypot(res[:, 0], res[:, 1]).reshape(flow.shape[:2]) <= kv_f(kv, "thr", 1.0))
    h, w = flow.shape[:2]
    par = np.array([[p[0, 0], p[1, 0], p[2, 0] - p[0, 0] * (w - 1) / 2 - p[1, 0] * (h - 1) / 2],
                    [p[0, 1], p[1, 1], p[2, 1] - p[0, 1] * (w - 1) / 2 - p[1, 1] * (h - 1) / 2]])
    return [res.reshape(flow.shape).astype(np.float32), par]


@op()
def flowStrain(i, kv):
    u, v = i[0][..., 0].astype(np.float64), i[0][..., 1].astype(np.float64)
    uy, ux = np.gradient(u)
    vy, vx = np.gradient(v)
    exy = 0.5 * (uy + vx)
    return [np.sqrt(ux ** 2 + vy ** 2 + 2 * exy ** 2).astype(np.float32), np.hypot(u, v).astype(np.float32)]


@op()
def onsetFlow(i, kv):
    out = [cv2.calcOpticalFlowFarneback(i[0], f, None, kv_f(kv, "pyrScale", 0.5), kv_i(kv, "levels", 3), kv_i(kv, "winsize", 15),
                                        kv_i(kv, "iters", 3), kv_i(kv, "polyN", 5), kv_f(kv, "polySigma", 1.2), 0) for f in i[1:]]
    return np.concatenate(out, 2)


@op()
def flowEpe(i, kv):
    e = np.hypot(*(i[0].astype(np.float64) - i[1].astype(np.float64)).transpose(2, 0, 1))
    if len(i) > 2:
        e = e[i[2] != 0]
    return np.array([[e.mean(), (e > 1).mean(), float(e.size)]])


@op()
def flowReg(i, kv):
    img, fl = i[0], i[1].astype(np.float64)
    g = np.hypot(cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3).astype(np.float64), cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3).astype(np.float64))
    t = np.abs(fl[:, 1:] - fl[:, :-1])[:-1].sum(2) + np.abs(fl[1:] - fl[:-1])[:, :-1].sum(2)
    m = g[:-1, :-1] < kv_f(kv, "thr", 40.0)
    return np.array([[t[m].sum() / max(m.sum(), 1), m.sum() / ((img.shape[0] - 1) * (img.shape[1] - 1)), g.mean()]])


@op()
def downUp(i, kv):
    h, w = i[0].shape[:2]
    f = kv_i(kv, "f", 4)
    sw, sh = max(1, (w + f // 2) // f), max(1, (h + f // 2) // f)
    return cv2.resize(cv2.resize(i[0], (sw, sh), interpolation=INTERP[kv_i(kv, "down", 4)]), (w, h), interpolation=INTERP[kv_i(kv, "up", 2)])


@op()
def getPerspectiveTransform(i, kv):
    return cv2.getPerspectiveTransform(i[0].astype(np.float32), i[1].astype(np.float32))


@op()
def warpPerspective(i, kv):
    h, w = i[0].shape[:2]
    fl = cv2.INTER_LINEAR | (cv2.WARP_INVERSE_MAP if kv_i(kv, "inv", 0) else 0)
    return cv2.warpPerspective(i[0], i[1], (kv_i(kv, "w", w), kv_i(kv, "h", h)), flags=fl, borderMode=cv2.BORDER_CONSTANT, borderValue=(kv_f(kv, "bval", 0.0),) * 4)


def _rot(kv):
    ya, pa = np.radians(kv_f(kv, "yaw", 0.0)), np.radians(kv_f(kv, "pitch", 0.0))
    return np.sin(ya), np.cos(ya), np.sin(pa), np.cos(pa)


@op()
def eq2persp(i, kv):
    src, w, h = i[0], kv_i(kv, "w", 640), kv_i(kv, "h", 480)
    sy, cy, sp, cp = _rot(kv)
    f = 0.5 * w / np.tan(np.radians(kv_f(kv, "fov", 90.0)) / 2)
    u, v = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
    x, y = (u - (w - 1) / 2) / f, (v - (h - 1) / 2) / f
    y1, z1 = y * cp + sp, -y * sp + cp
    x2, z2 = x * cy + z1 * sy, -x * sy + z1 * cy
    lon, lat = np.arctan2(x2, z2), np.arcsin(y1 / np.sqrt(x2 ** 2 + y1 ** 2 + z2 ** 2))
    H, W = src.shape[:2]
    mx = ((lon / (2 * np.pi) + 0.5) * W - 0.5).astype(np.float32)
    my = ((lat / np.pi + 0.5) * H - 0.5).astype(np.float32)
    pad = np.concatenate([src[:, -1:], src, src[:, :1]], 1)  # wrap in longitude
    return cv2.remap(pad, mx + 1, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


@op()
def persp2eq(i, kv):
    src, w, h = i[0], kv_i(kv, "w", 1024), kv_i(kv, "h", 512)
    sy, cy, sp, cp = _rot(kv)
    f = 0.5 * src.shape[1] / np.tan(np.radians(kv_f(kv, "fov", 90.0)) / 2)
    ii, jj = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
    lon, lat = ((ii + 0.5) / w - 0.5) * 2 * np.pi, ((jj + 0.5) / h - 0.5) * np.pi
    dx, dy, dz = np.cos(lat) * np.sin(lon), np.sin(lat), np.cos(lat) * np.cos(lon)
    x1, z1 = dx * cy - dz * sy, dx * sy + dz * cy
    y2, z2 = dy * cp - z1 * sp, dy * sp + z1 * cp
    ok = z2 > 1e-9
    zs = np.where(ok, z2, 1.0)
    mx = np.where(ok, f * x1 / zs + (src.shape[1] - 1) / 2, -10.0).astype(np.float32)
    my = np.where(ok, f * y2 / zs + (src.shape[0] - 1) / 2, -10.0).astype(np.float32)
    return cv2.remap(src, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(0,) * 4)


@op()
def lpq(i, kv):
    g, win = i[0].astype(np.float64), kv_i(kv, "win", 7)
    r, a = win // 2, 1.0 / win
    d = np.arange(-r, r + 1, dtype=np.float64)
    DY, DX = np.meshgrid(d, d, indexing="ij")
    code = 0
    win_view = np.lib.stride_tricks.sliding_window_view(g, (win, win))  # [y, x, dy, dx], dy, dx = 0..win-1
    for k, (fx, fy) in enumerate([(a, 0), (0, a), (a, a), (a, -a)]):
        ph = 2 * np.pi * (fx * DX + fy * DY)
        code = code + ((np.einsum("yxab,ab->yx", win_view, np.cos(ph)) > 1e-9).astype(np.int64) << (2 * k))
        code = code + ((np.einsum("yxab,ab->yx", win_view, np.sin(ph)) > 1e-9).astype(np.int64) << (2 * k + 1))
    return [code.astype(np.uint8), (np.bincount(code.ravel(), minlength=256) / code.size).reshape(1, 256)]


@op()
def evm(i, kv):
    x = i[0].astype(np.float64)
    s = x.copy()
    if kv_f(kv, "sigma", 0.0) > 0:
        s = np.stack([cv2.GaussianBlur(np.ascontiguousarray(i[0][..., t]), (0, 0), kv_f(kv, "sigma", 0.0)).astype(np.float64) for t in range(x.shape[2])], 2)
    lo, hi, al = kv_f(kv, "lo", 0.05), kv_f(kv, "hi", 0.4), kv_f(kv, "alpha", 20.0)
    l1 = l2 = s[..., 0].copy()
    out = np.empty_like(x)
    for t in range(x.shape[2]):
        l1 = l1 + hi * (s[..., t] - l1)
        l2 = l2 + lo * (s[..., t] - l2)
        out[..., t] = x[..., t] + al * (l1 - l2)
    return out.astype(np.float32)


# ---- fixtures ---------------------------------------------------------------------------------------------
def scene(seed, h=1080, w=1920):
    """A deterministic 1080p test picture with the statistics the ops care about: flat panels with sharp edges, a
    smooth colour field, text at several sizes, diagonal lines, circles, and noisy texture patches."""
    r = np.random.default_rng(seed)
    gy, gx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.stack([120 + 80 * np.sin(gx / 310 + seed) * np.cos(gy / 270), 110 + 70 * np.cos(gx / 190 - gy / 410),
                    100 + 90 * np.sin((gx + gy) / 520 + seed)], axis=2)
    img = np.clip(img, 0, 255).astype(np.uint8)
    for _ in range(90):
        x0, y0 = int(r.integers(0, w - 60)), int(r.integers(0, h - 40))
        x1, y1 = x0 + int(r.integers(30, 420)), y0 + int(r.integers(20, 260))
        cv2.rectangle(img, (x0, y0), (min(x1, w - 1), min(y1, h - 1)), tuple(int(c) for c in r.integers(0, 256, 3)), -1)
    for _ in range(60):
        org = (int(r.integers(0, w - 200)), int(r.integers(30, h - 10)))
        cv2.putText(img, "mojo-cv %d" % int(r.integers(0, 99999)), org, cv2.FONT_HERSHEY_SIMPLEX, float(r.uniform(0.4, 2.2)),
                    tuple(int(c) for c in r.integers(0, 256, 3)), int(r.integers(1, 4)), cv2.LINE_AA)
    for _ in range(50):
        cv2.line(img, (int(r.integers(0, w)), int(r.integers(0, h))), (int(r.integers(0, w)), int(r.integers(0, h))),
                 tuple(int(c) for c in r.integers(0, 256, 3)), int(r.integers(1, 4)), cv2.LINE_AA)
    for _ in range(40):
        cv2.circle(img, (int(r.integers(0, w)), int(r.integers(0, h))), int(r.integers(8, 90)),
                   tuple(int(c) for c in r.integers(0, 256, 3)), int(r.choice([-1, 1, 2, 3])), cv2.LINE_AA)
    for _ in range(25):
        x0, y0 = int(r.integers(0, w - 200)), int(r.integers(0, h - 150))
        ph, pw = int(r.integers(40, 150)), int(r.integers(60, 200))
        patch = img[y0:y0 + ph, x0:x0 + pw].astype(np.int16) + r.integers(-40, 41, (ph, pw, 3))
        img[y0:y0 + ph, x0:x0 + pw] = np.clip(patch, 0, 255).astype(np.uint8)
    return img


def make_fixtures(d):
    """Inputs named by the case rows. hd* are 1080p synthetic scenes (`scene`); the rest are synthetic too."""
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(7)
    A = scene(11)
    # the second frame: the same scene seen 0.6 degrees and (6.3, -4.6) px later, with sensor noise and a few new panels
    R = np.random.default_rng(12)
    Mb = cv2.getRotationMatrix2D((960, 540), 0.6, 1.0)
    Mb[:, 2] += (6.3, -4.6)
    B = cv2.warpAffine(A, Mb, (1920, 1080), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
    B = np.clip(B.astype(np.int16) + R.integers(-3, 4, B.shape), 0, 255).astype(np.uint8)
    for _ in range(12):
        x0, y0 = int(R.integers(0, 1700)), int(R.integers(0, 900))
        cv2.rectangle(B, (x0, y0), (x0 + int(R.integers(30, 200)), y0 + int(R.integers(20, 120))), tuple(int(c) for c in R.integers(0, 256, 3)), -1)
    fx = {"hd": A[:, :1920], "hd2": B[:, :1920]}
    fx["hdg"] = cv2.cvtColor(fx["hd"], cv2.COLOR_BGR2GRAY)
    fx["hdg2"] = cv2.cvtColor(fx["hd2"], cv2.COLOR_BGR2GRAY)
    fx["sm"], fx["sm2"] = fx["hd"][300:570, 400:880].copy(), fx["hd2"][300:570, 400:880].copy()
    fx["smg"], fx["smg2"] = fx["hdg"][300:570, 400:880].copy(), fx["hdg2"][300:570, 400:880].copy()
    fx["sm_lab"], fx["sm_luv"] = cv2.cvtColor(fx["sm"], cv2.COLOR_BGR2Lab), cv2.cvtColor(fx["sm"], cv2.COLOR_BGR2Luv)
    smf = fx["sm"].astype(np.float32) / 255
    fx["sm_lab_f"], fx["sm_luv_f"] = cv2.cvtColor(smf, cv2.COLOR_BGR2Lab), cv2.cvtColor(smf, cv2.COLOR_BGR2Luv)
    fx["bin"] = (fx["smg"] < 128).astype(np.uint8) * 255
    fx["binhd"] = (fx["hdg"] < 128).astype(np.uint8) * 255
    rim = np.full((400, 600), 150, np.uint8); rim[:, :24] = 30; rim[:, -18:] = 35; rim[:12, :] = 25
    fx["rimsyn"] = cv2.add(rim, (np.indices(rim.shape).sum(0) % 7).astype(np.uint8))  # dark tray rim on 3 sides
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
    # cornerSubPix start points: jittered corners where cv2's iteration has converged (10, 50 and 100 iterations agree);
    # on a slowly drifting point the result after 50 iterations is decided by float rounding and cv2's restore rule
    jit = gp + rng.uniform(-1.2, 1.2, gp.shape).astype(np.float32)
    fixed_ = []
    for pt in jit:
        c = [cv2.cornerSubPix(fx["smg"], pt.reshape(1, 1, 2).copy(), (3, 3), (-1, -1), (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_COUNT, n, 0.001)) for n in (10, 50, 100)]
        if max(np.abs(c[0] - c[1]).max(), np.abs(c[1] - c[2]).max()) < 1e-3:
            fixed_.append(pt)
    fx["sp_pts"] = np.array(fixed_[:80], np.float32)
    assert len(fx["sp_pts"]) >= 60, len(fixed_)
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
    fx["ess_six1"], fx["ess_six2"] = q1[12:18].copy(), q2[12:18].copy()
    fx["ess_five1"], fx["ess_five2"] = q1[12:17].copy(), q2[12:17].copy()
    fx["ess_clean1"], fx["ess_clean2"] = q1[12:].copy(), q2[12:].copy()
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
    outp = fx["pnp_img_pl"].copy()
    outp[:3] = rng.uniform(0, 640, (3, 2))
    fx["pnp_img_pl_out"] = np.vstack([outp, cv2.projectPoints(fx["pnp_obj_pl"][:6], rvp, tvp, Kc, fx["d4"])[0].reshape(-1, 2)])
    fx["pnp_obj_pl2"] = np.vstack([fx["pnp_obj_pl"], fx["pnp_obj_pl"][:6]])
    fx["pnp_four"] = np.array([[-1., -1., 0.], [1., -1., .3], [0., 1., -.2], [.2, .1, 1.]])
    fx["pnp_four_img"] = cv2.projectPoints(fx["pnp_four"], rvp, tvp, Kc, fx["d4"])[0].reshape(-1, 2)
    fx["pnp_img_noise"] = fx["pnp_img"] + np.random.default_rng(103).normal(0, .2, (40, 2))
    Af = np.array([[0.9, -0.3, 12.0], [0.25, 1.1, -7.0]])
    pa = rng.uniform(0, 300, (80, 2))
    pb = pa @ Af[:, :2].T + Af[:, 2]
    pb[:16] = rng.uniform(0, 300, (16, 2))
    fx["aff_from"], fx["aff_to"] = pa, pb
    fx["Rst"] = cv2.Rodrigues(np.array([0.01, -0.02, 0.005]))[0]
    fx["Tst"] = np.array([[-0.12], [0.003], [0.002]])
    fx["Tstv"] = np.array([[0.003], [-0.12], [0.002]])
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
    dic = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)
    sc = np.full((480, 640), 190, np.uint8)
    for mid, (ang, scale, ox, oy) in {7: (0.0, 1.0, 40, 40), 23: (0.5, 0.8, 330, 60), 42: (-0.9, 1.1, 120, 270), 3: (2.4, 0.7, 450, 280)}.items():
        mk = cv2.aruco.generateImageMarker(dic, mid, 90)
        mk = cv2.copyMakeBorder(mk, 15, 15, 15, 15, cv2.BORDER_CONSTANT, value=255)
        Mrot = cv2.getRotationMatrix2D((60, 60), np.degrees(ang), scale)
        Mrot[:, 2] += [ox, oy]
        warped = cv2.warpAffine(mk, Mrot, (640, 480), flags=cv2.INTER_LINEAR, borderValue=190)
        msk = cv2.warpAffine(np.ones_like(mk) * 255, Mrot, (640, 480), flags=cv2.INTER_NEAREST, borderValue=0)
        sc[msk > 0] = warped[msk > 0]
    fx["aruco_a"] = cv2.GaussianBlur(sc, (3, 3), 0)
    sc2 = np.full((240, 320), 120, np.uint8)
    mk = cv2.copyMakeBorder(cv2.aruco.generateImageMarker(dic, 11, 100), 20, 20, 20, 20, cv2.BORDER_CONSTANT, value=255)
    P = cv2.getPerspectiveTransform(np.float32([[0, 0], [140, 0], [140, 140], [0, 140]]), np.float32([[60, 40], [200, 55], [215, 190], [50, 170]]))
    wp = cv2.warpPerspective(mk, P, (320, 240), borderValue=120)
    mp = cv2.warpPerspective(np.ones_like(mk) * 255, P, (320, 240), flags=cv2.INTER_NEAREST)
    sc2[mp > 0] = wp[mp > 0]
    fx["aruco_b"] = sc2
    # grabCut inputs: a coloured scene (blobs on a textured background) and a scene crop
    gy, gx = np.mgrid[0:110, 0:150]
    sc3 = np.zeros((110, 150, 3), np.uint8)
    sc3[:] = (40, 90, 30)
    sc3 = np.clip(sc3.astype(np.int16) + rng.integers(-12, 13, sc3.shape), 0, 255).astype(np.uint8)
    cv2.ellipse(sc3, (75, 55), (32, 24), 20, 0, 360, (200, 60, 50), -1)
    cv2.circle(sc3, (60, 50), 10, (230, 200, 40), -1)
    sc3 = np.clip(sc3.astype(np.int16) + rng.integers(-10, 11, sc3.shape), 0, 255).astype(np.uint8)
    fx["gc_scene"] = sc3
    best_c, best_xy = -1, (0, 0)  # the scene crop with the most distinct colours
    for y0 in range(0, 1080 - 110, 20):
        for x0 in range(0, 1920 - 150, 30):
            c_ = len(np.unique(fx["hd"][y0:y0 + 110:3, x0:x0 + 150:3].reshape(-1, 3), axis=0))
            if c_ > best_c:
                best_c, best_xy = c_, (y0, x0)
    gs = fx["hd"][best_xy[0]:best_xy[0] + 110, best_xy[1]:best_xy[1] + 150].copy()
    obj = np.zeros_like(gs)
    obj[:] = (30, 160, 230)
    obj = np.clip(obj.astype(np.int16) + rng.integers(-25, 26, obj.shape), 0, 255).astype(np.uint8)
    om = np.zeros(gs.shape[:2], np.uint8)
    cv2.ellipse(om, (80, 55), (38, 28), -15, 0, 360, 255, -1)
    gs[om > 0] = obj[om > 0]  # a coloured object on a scene crop
    fx["gc_shot"] = gs
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
    # raw HOG boxes of cv2 4.x on hdg: the input of the groupRectangles row (hdg.mcv must exist before the call)
    mcv.save(fx["hdg"], os.path.join(d, "hdg.mcv"))
    code = ("import cv2,sys,numpy as np;sys.path.insert(0,%r);import mcv;h=cv2.HOGDescriptor();"
            "h.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector());"
            "r,_=h.detectMultiScale(mcv.load(%r),hitThreshold=-1.0,winStride=(8,8),padding=(0,0),scale=1.05,groupThreshold=0);"
            "mcv.save(np.array(r,np.int32).reshape(-1,4),%r)" % (os.path.join(ROOT, "tools"), os.path.join(d, "hdg.mcv"), os.path.join(d, "hog_raw.mcv")))
    raw = subprocess.run([PY4, "-c", code], capture_output=True, text=True)
    if raw.returncode:
        raise SystemExit("FAIL fixtures: HOG oracle (cv2 4.x at %s): %s" % (PY4, raw.stderr.strip()[-300:]))
    # the default people detector (3780 weights + bias) only exists in cv2 4.x
    sv = subprocess.run([PY4, "-c", "import cv2,sys;sys.stdout.buffer.write(cv2.HOGDescriptor_getDefaultPeopleDetector().astype('<f4').tobytes())"], capture_output=True)
    if sv.returncode or len(sv.stdout) != 3781 * 4:
        raise SystemExit("FAIL fixtures: the default people detector from cv2 4.x (%s) did not return 3781 weights" % PY4)
    fx["hog_svm"] = np.frombuffer(sv.stdout, "<f4").reshape(-1, 1).copy()
    # stockcheck: planted failures on the 1080p scene and a dithered ramp (blur, noise, JPEG blocks, banding,
    # blown exposure, colour cast, a fog band over the left quarter), plus the degenerate inputs
    H, S = fx["hd"], np.random.default_rng(31)
    def jpg(a, q): return cv2.imdecode(cv2.imencode(".jpg", a, [cv2.IMWRITE_JPEG_QUALITY, q])[1], cv2.IMREAD_COLOR)
    yy, xx = np.mgrid[0:1080, 0:1920]
    ramp = 40 + 150 * xx / 1919.0 + 30 * yy / 1079.0
    grad = np.stack([ramp * 0.9, ramp, ramp * 1.05], -1)
    fog = H.astype(np.float64)
    fog[:, :500] = 0.02 * fog[:, :500] + 0.98 * 215  # a white-out like db067, not a mild haze
    st = {"st_grad": np.clip(np.rint(grad + S.normal(0, 0.6, grad.shape)), 0, 255).astype(np.uint8),
          "st_band": (np.clip(np.rint(grad), 0, 255).astype(np.uint8) // 8) * 8,
          "st_blur": cv2.GaussianBlur(H, (0, 0), 3),
          "st_noise": np.clip(H.astype(np.float64) + S.normal(0, 12, H.shape), 0, 255).astype(np.uint8),
          "st_jpg95": jpg(H, 95), "st_jpg8": jpg(H, 8),
          "st_blown": np.clip(H.astype(np.float64) * 2.4, 0, 255).astype(np.uint8),
          "st_cast": np.clip(H.astype(np.float64) * (0.7, 1.0, 1.4), 0, 255).astype(np.uint8),
          "st_big": cv2.resize(H, (3072, 1728), interpolation=cv2.INTER_CUBIC),
          "st_sparkle": np.where(S.random(H.shape[:2])[..., None] < 0.12, 255, H).astype(np.uint8),  # 12 % of pixels clipped, scattered
          "st_fog": fog.astype(np.uint8), "st_flat": np.full((64, 64, 3), 128, np.uint8), "st_tiny": H[100:116, 200:216].copy()}
    for n, a in st.items():
        fx[n], fx[n + "g"] = a, cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    fx["ham_bits"] = S.integers(0, 2, (200, 64), dtype=np.uint8)
    for k in range(11):  # copies of rows 0..10 with k bits flipped: planted near-duplicates at distance k
        fx["ham_bits"][50 + k] = fx["ham_bits"][k]
        fx["ham_bits"][50 + k, :k] ^= 1
    # hyper: a face-sized flow (affine head motion + a mouth-corner blob), landmarks, an equirectangular picture, clips for
    # magnification; own seed so the fixtures above do not move
    Hr = np.random.default_rng(41)
    gy, gx = np.mgrid[0:96, 0:128].astype(np.float32)
    head = np.stack([0.02 * (gx - 64) - 0.015 * (gy - 48) + 2.0, 0.015 * (gx - 64) + 0.01 * (gy - 48) - 1.0], -1)
    blob = np.exp(-(((gx - 40) / 8) ** 2 + ((gy - 60) / 6) ** 2))[..., None] * np.array([1.5, -1.0], np.float32)
    fx["ff_flow"] = (head + blob + Hr.normal(0, 0.01, (96, 128, 2))).astype(np.float32)
    fx["ff_gt"] = (head + Hr.normal(0, 0.3, (96, 128, 2))).astype(np.float32)
    fx["ff_mask"] = ((((gx - 40) / 20) ** 2 + ((gy - 60) / 15) ** 2) > 1).astype(np.uint8) * 255
    fx["ff_img"] = fx["smg"][100:196, 100:228].copy()
    fx["smg3"] = cv2.warpAffine(fx["smg2"], np.float32([[1, 0, 1.5], [0, 1, -1.0]]), (480, 270), borderMode=cv2.BORDER_REFLECT)
    pts = np.array([[500, 300], [900, 330], [880, 760], [520, 740]], np.float64)
    can = np.array([[0, 0], [255, 0], [255, 255], [0, 255]], np.float64)
    fx["hom_src"], fx["hom_dst"] = pts, can
    fx["hom_inv"] = cv2.getPerspectiveTransform(can.astype(np.float32), pts.astype(np.float32))  # canonical -> picture
    fx["hom_fwd"] = cv2.getPerspectiveTransform(pts.astype(np.float32), can.astype(np.float32))  # picture -> canonical
    fx["eq_img"] = cv2.resize(fx["hd"], (1024, 512), interpolation=cv2.INTER_AREA)
    tt, xs = np.arange(32), np.arange(80, dtype=np.float64)[None, :, None]
    ys = np.arange(48, dtype=np.float64)[:, None, None]
    grat = 128 + 60 * np.sin(2 * np.pi * (xs - 0.4 * np.sin(2 * np.pi * tt / 16)[None, None, :]) / 20) + 5 * np.sin(ys / 7)
    edge = 60 + 130 / (1 + np.exp(-(xs - 40 - 1.0 * np.sin(2 * np.pi * tt / 16)[None, None, :]) / 1.5)) + 3 * np.sin(ys / 5)
    fx["evm_grat"] = (grat + Hr.normal(0, 0.5, grat.shape)).astype(np.float32)
    fx["evm_edge"] = (edge + Hr.normal(0, 0.5, edge.shape)).astype(np.float32)
    os.makedirs(os.path.join(d, "stock"), exist_ok=True)  # the same planted failures as image files, for scripts/mcv-stockcheck
    for n in ["hd", "hd2", *st]:
        if fx[n].shape[0] > 64:
            cv2.imwrite(os.path.join(d, "stock", n + ".png"), fx[n])
    # calibration (R9): vote counts for the Dirichlet-multinomial rows, scorers for temperature, ECE and abstention; own seed so
    # the fixtures above do not move. ok scorer: logits b, labels drawn from softmax(b); ov: logits 3 b, same labels
    Cr = np.random.default_rng(97)
    K = 7
    al = Cr.uniform(0.2, 20.0, (200, K))
    fx["cal_alpha"] = al
    fx["cal_cnt"] = np.stack([Cr.multinomial(int(n), Cr.dirichlet(a)) for n, a in zip(Cr.integers(1, 40, 200), al)]).astype(np.float64)
    fx["cal_alpha_edge"] = np.array([[0.05] * 4, [500.0] * 4, [0.05, 500.0, 0.3, 7.0], [1.0] * 4, [0.05] * 4, [30.0, 0.01, 2.0, 0.5]])
    fx["cal_cnt_edge"] = np.array([[0, 0, 0, 0], [1000, 0, 0, 0], [0, 400, 0, 3], [250, 250, 250, 250], [3, 0, 0, 0], [20, 0, 11, 1]], np.float64)
    pz = Cr.normal(0, 1.2, (300, K))
    pt = np.exp(pz) / np.exp(pz).sum(1, keepdims=True)
    fx["cal_vote_p"] = pt
    fx["cal_vote_cnt"] = np.stack([Cr.multinomial(10, Cr.dirichlet(8.0 * p)) for p in pt]).astype(np.float64)
    po = pt ** 3
    fx["cal_vote_p_over"] = po / po.sum(1, keepdims=True)

    def scorer(n, scale):
        b = Cr.normal(0, 1.5, (n, K))
        y = np.minimum((np.cumsum(_softmax(b, 1.0), 1) < Cr.random(n)[:, None]).sum(1), K - 1)
        return scale * b, y.astype(np.int32).reshape(-1, 1)

    fx["calf_z_ok"], fx["calf_y_ok"] = scorer(3000, 1.0)
    fx["calt_z_ok"], fx["calt_y_ok"] = scorer(3000, 1.0)
    fx["calf_z_ov"], fx["calf_y_ov"] = scorer(3000, 3.0)
    fx["calt_z_ov"], fx["calt_y_ov"] = scorer(3000, 3.0)
    fx["calf_y_shuf"] = Cr.permutation(fx["calf_y_ok"].reshape(-1)).astype(np.int32).reshape(-1, 1)
    fx["cal_Tfit_ov"] = np.array([[_cal_temp(fx["calf_z_ov"], fx["calf_y_ov"].reshape(-1))[0]]])
    fx["cal_thr_ok"] = np.array([[_cal_abstain(fx["calf_z_ok"], fx["calf_y_ok"].reshape(-1), 1.0, 0.2, None)[0]]])
    _emb_fixtures(fx)
    for n, a in fx.items():
        mcv.save(a, os.path.join(d, n + ".mcv"))


# ---- calibration (src/mojocv/calib.mojo; rows in tests/cases/fs-calib.txt) --------------------------------------
import math

_lg = np.vectorize(math.lgamma, otypes=[np.float64])


def _dm_rows(c, a):
    n, A = c.sum(1), a.sum(1)
    return -(_lg(n + 1) - _lg(c + 1).sum(1) + _lg(A) - _lg(n + A) + (_lg(c + a) - _lg(a)).sum(1))


def _grid_min(f, lo, hi, n=801, stages=3):
    """Minimum of f over x in [lo, hi] by nested grids: the oracle for the golden-section fits (x = log of the parameter)."""
    for _ in range(stages):
        xs = np.linspace(lo, hi, n)
        v = np.array([f(x) for x in xs])
        j = int(v.argmin())
        step = (hi - lo) / (n - 1)
        lo, hi = xs[j] - step, xs[j] + step
    return xs[j], v[j]


def _softmax(z, t):
    e = np.exp((z - z.max(1, keepdims=True)) / t)
    return e / e.sum(1, keepdims=True)


def _nll(z, y, t):
    return -np.log(np.maximum(_softmax(z, t)[np.arange(len(y)), y], 1e-300)).mean()


def _cal_temp(z, y):
    x, v = _grid_min(lambda x: _nll(z, y, math.exp(x)), math.log(0.05), math.log(20.0))
    return math.exp(x), v, _nll(z, y, 1.0)


def _cal_abstain(z, y, t, max_err, fixed):
    p = _softmax(z, t)
    conf, ok = p.max(1), (p.argmax(1) == y).astype(np.float64)
    thr = 2.0
    if fixed is not None:
        thr = fixed
    else:
        for c in np.unique(conf):  # ascending: the first threshold that meets the error limit has the largest coverage
            if 1.0 - ok[conf >= c].mean() <= max_err:
                thr = float(c)
                break
    kept = conf >= thr
    return thr, kept.mean(), (1.0 - ok[kept].mean()) if kept.any() else 0.0


def _plant(kv, key, val, tol=0.0, log=False):
    """The oracle asserts the planted truth a row names, so a pass means ours equals an oracle that equals the plant."""
    if key in kv:
        want, got = float(kv[key]), val
        if log:
            want, got = math.log(want), math.log(got)
        if abs(got - want) > float(kv.get("tol", tol)):
            raise SystemExit(f"planted {key}={kv[key]} but the oracle got {val}")


@op()
def calDm(i, kv):
    return _dm_rows(i[0], i[1]).reshape(-1, 1)


@op()
def calFitDm(i, kv):
    c, p = i[0], np.maximum(i[1], 1e-6)
    f = lambda x: _dm_rows(c, math.exp(x) * p).mean()
    x, v = _grid_min(f, math.log(0.01), math.log(10000.0))
    _plant(kv, "expect_s", math.exp(x), log=True)
    return np.array([[x, v, f(0.0)]])


@op()
def calTemp(i, kv):
    t, v, v1 = _cal_temp(i[0], i[1].reshape(-1))
    _plant(kv, "expect_T", t)
    return np.array([[t, v, v1]])


@op()
def calEval(i, kv):
    z, y = i[0], i[1].reshape(-1)
    t = float(i[2].reshape(-1)[0]) if len(i) > 2 else kv_f(kv, "T", 1.0)
    bins, p = kv_i(kv, "bins", 15), _softmax(z, t)
    conf, ok = p.max(1), (p.argmax(1) == y).astype(np.float64)
    b = np.clip(np.ceil(conf * bins).astype(int) - 1, 0, bins - 1)
    ece = sum((b == k).mean() * abs(ok[b == k].mean() - conf[b == k].mean()) for k in range(bins) if (b == k).any())
    flag = float(ece > kv_f(kv, "max_ece", 0.05) and conf.mean() > ok.mean())
    _plant(kv, "expect", flag)
    return np.array([[ece, _nll(z, y, t), ok.mean(), flag]])


@op()
def calAbstain(i, kv):
    z, y = i[0], i[1].reshape(-1)
    thr, cov, err = _cal_abstain(z, y, kv_f(kv, "T", 1.0), kv_f(kv, "max_err", 0.1), float(i[2].reshape(-1)[0]) if len(i) > 2 else None)
    _plant(kv, "expect_cov", cov)
    if "err_limit" in kv and err > float(kv["err_limit"]):
        raise SystemExit(f"held-out error {err} above the limit {kv['err_limit']}")
    if "cov_min" in kv and cov < float(kv["cov_min"]):
        raise SystemExit(f"coverage {cov} below {kv['cov_min']}")
    return np.array([[thr, cov, err]])


# ---- embedding index (src/mojocv/embindex.mojo; rows in tests/cases/fs-index.txt; plan R8) -----------------------
def _emb_fixtures(fx):
    """Own seed. Vectors, not pictures: the twins are a planted noise level (cosine .995 to .89) standing for crop, rescale, JPEG
    and colour changes; the picture-level twins (SigLIP of real crops) are not built."""
    Er, D = np.random.default_rng(211), 768
    unit = lambda v: np.divide(v, np.linalg.norm(v, axis=1, keepdims=True), out=np.zeros_like(v), where=np.linalg.norm(v, axis=1, keepdims=True) > 0)
    db = Er.normal(0, 1, (400, D))
    db[399] = 0.0  # a zero row: cosine 0 with everything
    q = Er.normal(0, 1, (12, D))
    q[:8] = db[Er.choice(399, 8, replace=False)] + 0.3 * q[:8]
    q[11] = 0.0
    fx["emb_db"], fx["emb_q"] = db.astype(np.float32), q.astype(np.float32)
    dd = db.copy(); dd[250] = dd[10]  # exact duplicates 10 and 250: they tie and the lower row ranks first
    fx["emb_db_dup"] = dd.astype(np.float32)
    fx["emb_q_dup"] = np.vstack([db[10], q[1:6]]).astype(np.float32)
    fx["emb_db_small"] = db[:5].astype(np.float32)
    fx["emb_db_unit"] = unit(db).astype(np.float32)
    base = Er.normal(0, 1, (300, D))
    for j in range(20):  # wrong-item near duplicates: item 100+j has cosine 0.9 with item j
        base[100 + j] = 0.9 * base[j] / np.linalg.norm(base[j]) * np.linalg.norm(base[100 + j]) + 0.436 * base[100 + j]
    fx["emb_tw_db"] = base.astype(np.float32)
    sig = np.repeat([0.1, 0.2, 0.3, 0.5], 10)  # crop, rescale, JPEG, colour stand-ins
    fx["emb_tw_q"] = (base[:40] + sig[:, None] * Er.normal(0, 1, (40, D))).astype(np.float32)
    fx["emb_tw_truth"] = np.arange(40, dtype=np.int32).reshape(-1, 1)
    dd = Er.normal(0, 1, (160, D))
    dd[100:140] = dd[:40] + 0.05 * Er.normal(0, 1, (40, D))  # same item again: cosine 0.9988
    dd[140:160] = dd[40:60] + 0.29 * Er.normal(0, 1, (20, D))  # another item that looks alike: cosine 0.96
    fx["emb_dd"] = dd.astype(np.float32)
    ang = np.radians([0, 20, 40, 60])
    ch = np.zeros((4, 8)); ch[:, 0], ch[:, 1] = np.cos(ang), np.sin(ang)
    fx["emb_chain"] = ch.astype(np.float32)


def _emb_unit(m, unit=False):
    m = m.astype(np.float64)
    n = np.linalg.norm(m, axis=1, keepdims=True)
    return m if unit else np.divide(m, n, out=np.zeros_like(m), where=n > 0)


@op()
def embTopK(i, kv):
    db, q, k = _emb_unit(i[0], kv_i(kv, "norm", 1) == 0), _emb_unit(i[1]), kv_i(kv, "k", 5)
    idx, sc = np.full((len(q), k), -1, np.int32), np.full((len(q), k), -2.0, np.float32)
    for r, u in enumerate(q):
        s = (db * u).sum(1)
        for t, j in enumerate(sorted(range(len(s)), key=lambda j: (-int(np.rint(s[j] * 1e9)), j))[:k]):
            idx[r, t], sc[r, t] = j, s[j]
    if len(i) > 2 and "hit_min" in kv:  # planted twins: the original item must rank first
        hit = (idx[:, 0] == i[2].reshape(-1)).mean()
        if hit < float(kv["hit_min"]):
            raise SystemExit(f"planted twins: top-1 is the original in {hit} of the queries, want {kv['hit_min']}")
    if kv_i(kv, "expect_tie", 0):  # the exact duplicates 10 and 250 rank 10 first
        if list(idx[0, :2]) != [10, 250]:
            raise SystemExit(f"planted tie 10/250 ranks {list(idx[0, :2])}")
    return [idx, sc]


@op()
def embNorm(i, kv): return _emb_unit(i[0]).astype(np.float32)


@op()
def embDup(i, kv):
    u, thr = _emb_unit(i[0]), kv_f(kv, "thr", 0.95)
    rep = np.arange(len(u), dtype=np.int32)
    for a in range(len(u)):
        for b in range(a):
            if rep[b] == b and (u[a] * u[b]).sum() >= thr:
                rep[a] = b
                break
    if "expect_merged" in kv and int((rep != np.arange(len(u))).sum()) != int(kv["expect_merged"]):
        raise SystemExit(f"planted {kv['expect_merged']} merged rows but the oracle merged {int((rep != np.arange(len(u))).sum())}")
    return rep.reshape(-1, 1)


# ---- grounding baseline (src/mojocv/ground.mojo; rows in tests/cases/fs-ground.txt; plan R21a) ----------------
_G_STOP = " click tap press push select open on the a an to button icon link field tab menu please then and "


def _g_tok(s, drop):
    out = []
    for t in re.findall("[A-Za-z0-9\u0080-\U0010ffff]+", s):
        t = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in t)
        if not (drop and f" {t} " in _G_STOP) and t not in out:
            out.append(t)
    return out


@op()
def ground(i, kv):
    f = [l.split("\t") for l in open(kv["elems"], encoding="utf-8").read().split("\n")]
    f = [r for r in f if len(r) >= 9 and r[0] != "idx"][: kv_i(kv, "rows", 1 << 30)]
    lab = [_g_tok(r[2] + " " + r[3], False) for r in f]
    clk = [r[4] == "true" for r in f]
    bx = [[int(float(v)) for v in r[5:9]] for r in f]
    dx, dy, w, h, n = kv_i(kv, "dx", 0), kv_i(kv, "dy", 0), kv_i(kv, "w", 0), kv_i(kv, "h", 0), len(f)
    stale = w > 0 and h > 0 and any(b[0] + dx < 0 or b[1] + dy < 0 or b[2] + dx > w or b[3] + dy > h for b in bx)
    area = lambda b: (b[2] - b[0]) * (b[3] - b[1])
    inside = lambda a, b: a[0] >= b[0] and a[1] >= b[1] and a[2] <= b[2] and a[3] <= b[3]
    res = []
    for q in kv.get("qs", "").split("|"):
        qt = _g_tok(q, True)
        sc = [0.0 if not qt or not lab[e] else 2.0 * sum(t in lab[e] for t in qt) / (len(qt) + len(lab[e])) for e in range(n)]
        best = max(sc, default=0.0)
        cand = [e for e in range(n) if best > 0 and sc[e] == best]
        sel = min(cand, key=lambda e: (not clk[e], area(bx[e]), e)) if cand else -1
        second = max([sc[e] for e in range(n) if sel >= 0 and e != sel and not (inside(bx[e], bx[sel]) or inside(bx[sel], bx[e]))], default=0.0)
        margin = best - second
        ab = sel < 0 or best < kv_f(kv, "thr", 0.5) or margin < kv_f(kv, "margin", 0.05) or stale
        cx = cy = -1.0
        if not ab:
            cx, cy = (bx[sel][0] + bx[sel][2] + 2 * dx) / 2.0, (bx[sel][1] + bx[sel][3] + 2 * dy) / 2.0
        res.append([-1.0 if ab else float(sel), best, margin if sel >= 0 else 0.0, float(ab), cx, cy, float(stale)])
    if "exp" in kv:  # planted truth: the intended element per query (-1 = must abstain). wrong = pointed at another element
        ex = [int(v) for v in kv["exp"].split(",")]
        ok = sum(int(r[0]) == e for r, e in zip(res, ex))
        wrong = sum(int(r[0]) >= 0 and int(r[0]) != e for r, e in zip(res, ex))
        print(f"ground: {ok} of {len(ex)} right, {wrong} wrong target, {sum(r[3] == 1 for r in res)} abstained")
        if wrong > kv_i(kv, "wrong_max", 0) or ok < kv_i(kv, "ok_min", 0):
            raise SystemExit(f"planted: {ok} right (want >= {kv_i(kv, 'ok_min', 0)}), {wrong} wrong (want <= {kv_i(kv, 'wrong_max', 0)})")
    return np.array(res, np.float64)


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


BENCH_NOTES = """- **Parallel dispatch**: `max.algorithm.parallelize` with the default 16 workers costs about 215 us per region (best of
  50 trivial regions); with 8 workers (the physical cores) it costs about 8 us, so `core.par` uses 8 and takes 16 only for
  regions that run for milliseconds. Allocating and zero-filling a 2 MB `Mat` is 18 us.
- **Read the ratios with care.** One run of this table is one sample on a shared desktop: a row near 1.0 can land on either
  side, and a loaded run of the same binary moves a row by up to a factor of two. `tools/abbench.py OLD_BIN` runs an old
  build, the current build and cv2 back to back per row, which is the fair comparison when the machine is not quiet.
- Point-set ops (projectPoints, estimateAffine2D, stereoRectify) take microseconds on both sides; 0.00 ms entries are
  below the timer's resolution, not a result."""


def write_md(path, table):
    hd = [t for t in table if t[4]]
    other = [t for t in table if not t[4]]

    def fmt(rs):
        out = ["| op | row | ours ms | cv2 ms | ours/cv2 |", "|---|---|---:|---:|---:|"]
        for opn, cid, a, b, _ in rs:
            if a is None or b is None:
                out.append(f"| {opn} | {cid} | n/a | n/a | |")
                continue
            ratio = f"{a / b:.2f}" if b > 0.005 else "n/a"
            out.append(f"| {opn} | {cid} | {a:.2f} | {b:.2f} | {ratio}{' **faster**' if b > 0.005 and a < b else ''} |")
        return "\n".join(out)

    ok = [t for t in hd if t[2] and t[3] and t[3] > 0.005]
    faster = sum(1 for t in ok if t[2] < t[3])
    close = sum(1 for t in ok if t[3] <= t[2] <= 1.5 * t[3])
    slow = ', '.join(sorted({t[1] for t in ok if t[2] > 1.5 * t[3]}))
    with open(path, "w") as f:
        f.write(f"""# 2D speed rows: mojo-cv vs cv2 5.0

Method: `tests/run.sh --bench-all --md docs/bench.md`. Each row runs the same op in one resident process with `reps=5`
and keeps the best wall time of the compute only (file load and save excluded), ours via `.bin/mojo-cv`, cv2 via
`tools/oracle_cv2.py` (numpy in, cv2 call, best of 5). Both sides use all threads of the 7800X3D; CPU only, no GPU.
Inputs are the same `.mcv` fixtures (`hd*` = 1920x1080 synthetic scenes from `scene()` in `tools/oracle_cv2.py`, the rest
smaller). Target: ours <= cv2. **Misses are listed as measured; nothing is hidden.** The HOG rows time cv2 4.8.1
(cv2 5.0 has no HOG).

1080p rows: {faster} of {len(ok)} faster than cv2, {close} more within 1.5x, the rest slower (ratio column).

Slower than cv2 in this run: {slow}.

{BENCH_NOTES}

## 1920x1080 rows

{fmt(hd)}

## Other sizes (270x480 and smaller, point sets, stereo pairs)

{fmt(other)}
""")


def suite(files, bench, every=False, md=None):
    work = os.path.join(ROOT, ".work", "t")
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(ROOT, ".bin", "mojo-cv")
    npass = nfail = 0
    table = []
    for f, (cid, opn, ins, kv, cmps) in rows(files):
        paths = [fpath(n) for n in ins]
        kvs = [f"{k}={v}" for k, v in kv.items()]
        hd = any(n.startswith("hd") for n in ins)
        if bench and not hd and not every:
            continue
        kvs_b = kvs + (["reps=5"] if bench else [])
        o, r = os.path.join(work, cid + ".ours"), os.path.join(work, cid + ".ref")
        for p in (o, r):
            for g in [p] + [f"{p}.{n}" for n in range(1, 6)]:
                if os.path.exists(g):
                    os.remove(g)
        try:
            tr = subprocess.run([PY4 if opn in HOG_OPS else sys.executable, "-I", __file__, opn, r, *paths, *kvs_b], capture_output=True, text=True)
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
            table.append((opn, cid, time_of(to.stdout), time_of(tr.stdout), hd))
    print(f"rows: {npass + nfail}  pass: {npass}  fail: {nfail}")
    if bench:
        print("| op | row | ours ms | cv2 ms | ratio |\n|---|---|---|---|---|")
        for opn, cid, a, b, _ in table:
            print(f"| {opn} | {cid} | {a:.2f} | {b:.2f} | {a / b:.2f} |" if a and b else f"| {opn} | {cid} | {a} | {b} | |")
        if md:
            write_md(md, table)
    return nfail


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--suite":
        bench = "--bench" in a or "--bench-all" in a
        md = a[a.index("--md") + 1] if "--md" in a else None
        files = [x for x in a[1:] if not x.startswith("--") and x != md]
        sys.exit(1 if suite(files, bench, "--bench-all" in a, md) else 0)
    if a and a[0] == "--fixtures":
        make_fixtures(a[1])
        sys.exit(0)
    run_one(a[0], a[1], [x for x in a[2:] if "=" not in x], dict(x.split("=", 1) for x in a[2:] if "=" in x))
