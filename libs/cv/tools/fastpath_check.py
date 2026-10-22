"""Odd shapes and 1/3/4 channels through the uint8 fast paths (resize 2x, GaussianBlur 5, pyrDown) against cv2, bit exact.
  run from the repo root under `~/iTools/video/camera-motion/v/bin/python -I tools/fastpath_check.py`"""
import sys, numpy as np, cv2, subprocess
sys.path.insert(0, "tools"); import mcv
rng = np.random.default_rng(3)
bad = 0
for (h, w, ch) in [(40, 200, 4), (41, 203, 4), (30, 64, 4), (16, 9, 4), (50, 301, 1), (50, 301, 3)]:
    a = rng.integers(0, 256, (h, w, ch), dtype=np.uint8)
    if ch == 1: a = a[..., 0]
    mcv.save(a, ".work/c4.mcv")
    for name, args, ref in [("pyrDown", [], cv2.pyrDown(a)), ("GaussianBlur", ["ksize=5", "sigma=0"], cv2.GaussianBlur(a, (5, 5), 0))] + ([("resize", ["w=%d" % (w // 2), "h=%d" % (h // 2), "interp=1"], cv2.resize(a, (w // 2, h // 2), interpolation=cv2.INTER_LINEAR))] if w % 2 == 0 and h % 2 == 0 else []):
        subprocess.run([".bin/mojo-cv", name, ".work/c4o.mcv", ".work/c4.mcv", *args], check=True, capture_output=True)
        o = mcv.load(".work/c4o.mcv")
        d = np.abs(o.astype(int) - ref.reshape(o.shape).astype(int)).max()
        print(name, h, w, ch, "maxdiff", d); bad += d > 0
print("BAD", bad)
