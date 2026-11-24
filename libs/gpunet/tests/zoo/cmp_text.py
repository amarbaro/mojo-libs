"""cmp_text.py OUTDIR [TOL_COS TOL_ABS TOL_PAIR] (defaults 0.999, 1e-3 of the largest oracle value, 1e-4): GPU text tower rows (OUTDIR/{hidden,proj,emb}.f32) against the PyTorch oracle in this directory.
Prints per-stage cosine and max abs, the paired-score matrix error, top-1 rank agreement, norm, and the shuffled-caption control."""
import sys, numpy as np
d = sys.argv[1]; here = __file__.rsplit("/", 1)[0] if "/" in __file__ else "."
tc = float(sys.argv[2]) if len(sys.argv) > 2 else 0.999; ta = float(sys.argv[3]) if len(sys.argv) > 3 else 1e-3; tp = float(sys.argv[4]) if len(sys.argv) > 4 else 1e-4
ld = lambda p: np.fromfile(p, np.float32).reshape(200, 768).astype(np.float64)
cos = lambda a, b: (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1))
bad = 0; res = {}
for n in ("hidden", "proj", "emb"):
    g, r = ld(f"{d}/{n}.f32"), ld(f"{here}/siglip-v1-text.{n}.f32")
    c, m = cos(g, r), np.abs(g - r).max()
    res[n] = (g, r)
    print(f"{n}: rows 200 cosine min {c.min():.9f} mean {c.mean():.9f} max abs {m:.2e}")
    if c.min() < tc or m > ta * (np.abs(r).max() if n != "emb" else 1.0): bad += 1; print(f"FAIL {n}: below cosine {tc} or max abs above {ta}")
g, r = res["emb"]
nrm = np.abs(np.linalg.norm(g, axis=1) - 1).max(); print(f"normalisation: max | |emb| - 1 | {nrm:.2e}")
gp = res["proj"][0]; nn = np.abs(gp / np.linalg.norm(gp, axis=1, keepdims=True) - g).max()
print(f"normalisation: emb equals proj / |proj| within {nn:.2e}")
if nrm > 1e-5 or nn > 1e-5: bad += 1; print("FAIL normalisation")
sg, sr = g @ g.T, r @ r.T                      # paired text-text scores, all 200 x 200
pe = np.abs(sg - sr).max(); print(f"paired scores: 200 x 200 cosine matrix max abs diff {pe:.2e}")
if pe > tp: bad += 1; print(f"FAIL paired scores: above {tp}")
sgr = g @ r.T                                  # ranking: the oracle's own top-1 neighbour (self excluded) must score as high under the GPU rows
np.fill_diagonal(sg, -2); np.fill_diagonal(sr, -2)
ng = sg.argmax(1); mis = int((sr[np.arange(200), ng] < sr.max(1) - 1e-4).sum())
print(f"ranking: top-1 neighbour of {200 - mis} of 200 rows is a tie or equal within 1e-4 of the oracle's"); 
if mis: bad += 1; print(f"FAIL ranking: {mis} rows differ")
rng = np.random.default_rng(0); sh = rng.permutation(200); sh = np.where(sh == np.arange(200), (sh + 1) % 200, sh)
uniq = np.array([len(set(map(tuple, r.round(4)[[i, j]]))) == 2 for i, j in zip(range(200), sh)])
c_ok, c_sh = cos(g, r).mean(), cos(g[uniq], r[sh][uniq]).mean()
print(f"control: shuffled captions mean cosine {c_sh:.4f} vs paired {c_ok:.6f} (margin required: paired - shuffled > 0.05)")
if c_ok - c_sh <= 0.05: bad += 1; print("FAIL control: shuffled captions not separated")
print(f"FAIL cmp_text: {bad} checks" if bad else "PASS cmp_text"); sys.exit(1 if bad else 0)
