"""fs-stream and fs-gpu2 rows (full-stack P1: R4, R3a, R3b). tools/oracle_cv2.py has no stream op and another owner, so this
runner adds the numpy oracle of src/mojocv/stream.mojo to oracle_cv2.OPS and runs the rows of tests/cases/fs-*.txt itself.

  fs_suite.py prep                     decode the fs-h2 frames into tests/fixtures/fs2_*.mcv (CPU decoders only: magick, cv2)
  fs_suite.py h2                       our tile masks and GPU absdiff against the fs-h2 references (absdiff_ref.json, absdiff twin PNG)
  fs_suite.py rows [--no-arm] CASES..  run rows: ours (MCV_BIN, default .bin/mojo-cv) against the oracle with the row's comparison
A gpu=1 row is also run without gpu=1: the GPU output must equal it byte for byte (float32 outputs: within 1e-6).
A row with gpu=1 must print `GPU-ARM` (the GPU kernel ran); a row id starting `fb_` must not (a parameter the kernels do not
cover: the CPU answer, reported). --no-arm (no accelerator visible) requires the marker absent on every row.
Exit 0 all pass, 1 a failure, 3 a missing precondition (prints a BLOCK line)."""
import glob, json, os, subprocess, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import oracle_cv2 as oc  # noqa: E402
import mcv  # noqa: E402
import cv2  # noqa: E402

FIX = os.path.join(ROOT, "tests", "fixtures")
H2 = os.environ.get("FS_H2", os.path.join(FIX, "fs-h2"))
EXE = os.environ.get("MCV_BIN", os.path.join(ROOT, ".bin", "mojo-cv"))


# ---- oracle of stream.mojo --------------------------------------------------------------------------------------------
def tile_max(a, b, tile):
    d = np.abs(a.astype(np.int16) - b.astype(np.int16))
    if d.ndim == 3:
        d = d.max(axis=2)
    h, w = d.shape
    r, c = -(-h // tile), -(-w // tile)
    p = np.zeros((r * tile, c * tile), np.int16)
    p[:h, :w] = d
    return p.reshape(r, tile, c, tile).max(axis=(1, 3)).astype(np.uint8)


def stream_run(frames, tile, thr, keyfrac, maxgap):
    base, since, rows = None, 0, []
    for f in frames:
        nt = (-(-f.shape[0] // tile)) * (-(-f.shape[1] // tile))
        if base is None or base.shape != f.shape:
            base, since = f.copy(), 0
            rows.append([0, nt, nt, 0])
            continue
        tm = tile_max(base, f, tile)
        dirty = tm > thr
        nd = int(dirty.sum())
        sm = int(tm[~dirty].max()) if (~dirty).any() else 0
        since += 1
        if (maxgap > 0 and since >= maxgap) or (keyfrac > 0 and nd > 0 and nd >= keyfrac * nt):
            base, since, d = f.copy(), 0, 0
        elif nd == 0:
            d = 1
        else:
            d = 2
            for ty, tx in zip(*np.nonzero(dirty)):
                base[ty * tile:(ty + 1) * tile, tx * tile:(tx + 1) * tile] = f[ty * tile:(ty + 1) * tile, tx * tile:(tx + 1) * tile]
        rows.append([d, nd, nt, sm])
    return [np.array(rows, np.int32), base]


@oc.op("streamDirty")
def streamDirty(i, kv):
    tm = tile_max(i[0], i[1], oc.kv_i(kv, "tile", 16))
    return [tm, np.where(tm > oc.kv_i(kv, "thr", 16), 255, 0).astype(np.uint8)]


@oc.op("streamRun")
def streamRun(i, kv):
    return stream_run(i, oc.kv_i(kv, "tile", 16), oc.kv_i(kv, "thr", 16), oc.kv_f(kv, "keyfrac", 0.5), oc.kv_i(kv, "maxgap", 30))


def block(msg):
    print("BLOCK fs_suite: " + msg)
    sys.exit(3)


def ours(op, out, paths, kvs):
    return subprocess.run([EXE, op, out, *paths, *kvs], capture_output=True, text=True)


# ---- prep ---------------------------------------------------------------------------------------------------------------
def prep():
    need = ["stream/A.png", "stream/B_changed_tile.png", "stream/C_same.png", "stream/B_px16.png", "stream/B_border16.png",
            "stream/absdiff_ref.json", "stream/absdiff_A_vs_B_changed_tile.png"] + [f"stream/A_q{q}.jpg" for q in (30, 50, 75, 85, 95)]
    for n in need:
        if not os.path.isfile(os.path.join(H2, n)):
            block(f"fs-h2 fixture {n} missing under {H2} (set FS_H2; the lane H2 commit 67a11b12 holds it)")
    r = subprocess.run(["sha256sum", "-c", "--quiet", "SHA256SUMS"], cwd=H2, capture_output=True, text=True)
    if r.returncode:
        print("FAIL prep: fs-h2 SHA256SUMS does not verify: " + r.stdout[:200])
        sys.exit(1)
    os.makedirs(FIX, exist_ok=True)
    names = {"A": "A.png", "Bt": "B_changed_tile.png", "C": "C_same.png", "B16": "B_px16.png", "BB": "B_border16.png"}
    for q in (30, 50, 75, 85, 95):
        names[f"Aq{q}"] = f"A_q{q}.jpg"
    for k, f in names.items():  # decoder one: ImageMagick (scripts/img2mcv.sh)
        subprocess.run([os.path.join(ROOT, "scripts", "img2mcv.sh"), os.path.join(H2, "stream", f), os.path.join(FIX, f"fs2_{k}.mcv"), "bgr"], check=True)
    for q in (30, 50, 75, 85, 95):  # decoder two: the cv2 build (the benign control: one file, two decoders, no motion)
        mcv.save(cv2.imread(os.path.join(H2, "stream", f"A_q{q}.jpg")), os.path.join(FIX, f"fs2_Aq{q}c.mcv"))
    a, bb = mcv.load(os.path.join(FIX, "fs2_A.mcv")), mcv.load(os.path.join(FIX, "fs2_BB.mcv"))
    mcv.save(np.ascontiguousarray(a[:445, :637]), os.path.join(FIX, "fs2_oddA.mcv"))  # sizes that leave partial tiles on both axes
    mcv.save(np.ascontiguousarray(bb[:445, :637]), os.path.join(FIX, "fs2_oddBB.mcv"))
    mcv.save(np.ascontiguousarray(np.dstack([a, a[:, :, 0]])), os.path.join(FIX, "fs2_A4.mcv"))  # four channels
    mcv.save(np.ascontiguousarray(np.dstack([bb, bb[:, :, 1]])), os.path.join(FIX, "fs2_BB4.mcv"))
    mcv.save(np.ascontiguousarray(cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)), os.path.join(FIX, "fs2_Ag.mcv"))
    mcv.save(np.ascontiguousarray(a.astype(np.float32) / 255.0), os.path.join(FIX, "fs2_Af.mcv"))  # float32 three channels
    for k in range(1, 5):  # a slow drift: +6 per frame, under the threshold 16 for two frames
        mcv.save(np.ascontiguousarray(np.clip(a.astype(np.int16) + 6 * k, 0, 255).astype(np.uint8)), os.path.join(FIX, f"fs2_D{k}.mcv"))
    print(f"PASS prep: {len(names) + 5 + 6 + 4} fs2 frames from {H2}")


# ---- h2 reference check -----------------------------------------------------------------------------------------------
def h2():
    ref = json.load(open(os.path.join(H2, "stream", "absdiff_ref.json")))
    thr = ref["threshold"]
    bad = 0
    pairs = {"A_vs_B_changed_tile": "Bt", "A_vs_B_px16": "B16", "A_vs_B_border16": "BB", "A_vs_C_same": "C"}
    pairs.update({f"A_vs_A_q{q}": f"Aq{q}" for q in (30, 50, 75, 85, 95)})
    work = os.path.join(ROOT, ".work", "fs2")
    os.makedirs(work, exist_ok=True)
    for name, key in pairs.items():
        for tile in ref["grids_px"]:
            o = os.path.join(work, f"{name}.{tile}")
            r = ours("streamDirty", o, [os.path.join(FIX, "fs2_A.mcv"), os.path.join(FIX, f"fs2_{key}.mcv")], [f"tile={tile}", f"thr={thr}"])
            if r.returncode:
                print(f"FAIL h2 {name} t{tile}: ours failed: {(r.stdout + r.stderr)[-200:]}")
                bad += 1
                continue
            tm, mask = mcv.load(o), mcv.load(o + ".1")
            got = [[int(y), int(x)] for y, x in zip(*np.nonzero(mask))]
            want = ref["pairs"][name][f"dirty_tiles_{tile}"]
            ok = got == want
            if tile == 64:
                ok = ok and tm.tolist() == ref["pairs"][name]["tile_max_64"]
            print(("PASS" if ok else "FAIL"), f"h2 {name} tile={tile}: {len(got)} dirty tiles, reference {len(want)}" + ("" if ok else f" (first got {got[:3]} want {want[:3]})"))
            bad += not ok
    # the JPEG sweep: the plan's "zero tiles" holds for two decodes of one JPEG setting (decoder noise stays under the threshold);
    # against the lossless source every tile of the test texture is dirty at thr 16 (the reference above): codec noise is reported, not hidden
    for q in (30, 50, 75, 85, 95):
        o = os.path.join(work, f"jpegdec{q}")
        r = ours("streamDirty", o, [os.path.join(FIX, f"fs2_Aq{q}.mcv"), os.path.join(FIX, f"fs2_Aq{q}c.mcv")], [f"thr={thr}"])
        tm, mask = mcv.load(o), mcv.load(o + ".1")
        ok = r.returncode == 0 and not mask.any()
        print(("PASS" if ok else "FAIL"), f"h2 jpeg q{q} magick vs cv2 decode: dirty tiles {int((mask > 0).sum())}, largest change {int(tm.max())} (thr {thr})")
        bad += not ok
    # GPU absdiff against the lossless twin of H2
    o = os.path.join(work, "ad_gpu")
    r = ours("absdiff", o, [os.path.join(FIX, "fs2_A.mcv"), os.path.join(FIX, "fs2_Bt.mcv"), "gpu=1"], [])
    twin = cv2.imread(os.path.join(H2, "stream", "absdiff_A_vs_B_changed_tile.png"), cv2.IMREAD_UNCHANGED)
    got = mcv.load(o).max(axis=2) if r.returncode == 0 else None
    ok = got is not None and "GPU-ARM absdiff uint8" in r.stdout and twin.shape == got.shape and (got == twin).all()
    print(("PASS" if ok else "FAIL"), "h2 absdiff twin: GPU absdiff (max over channels) equals the lossless PNG;", "GPU-ARM seen" if "GPU-ARM" in r.stdout else "NO GPU-ARM line")
    bad += not ok
    sys.exit(1 if bad else 0)


# ---- rows -------------------------------------------------------------------------------------------------------------
def rows_run(files, no_arm):
    work = os.path.join(ROOT, ".work", "fs2rows")
    os.makedirs(work, exist_ok=True)
    npass = nfail = 0
    for f, (cid, opn, ins, kv, cmps) in oc.rows(files):
        paths = [oc.fpath(n) for n in ins]
        for p in paths:
            if not os.path.isfile(p):
                block(f"input {p} of row {cid} missing (run: fs_suite.py prep)")
        kvs = [f"{k}={v}" for k, v in kv.items()]
        twin = kv.get("gpu") == "1"
        o = os.path.join(work, cid + ".ours")
        for g in glob.glob(o + "*"):
            os.remove(g)
        arm = False
        try:
            ref = oc.outputs(oc.OPS[opn]([mcv.load(p) for p in paths], kv))
            t = ours(opn, o, paths, kvs)
            ok, msg = True, ""
            arm = "GPU-ARM" in t.stdout
            want_arm = kv.get("gpu") == "1" and not cid.startswith("fb_") and not no_arm
            if t.returncode:
                ok, msg = False, "ours failed: " + (t.stdout + t.stderr).strip()[-300:]
            elif want_arm and not arm:
                ok, msg = False, "gpu=1 but no GPU-ARM line: the GPU arm did not run (" + t.stdout.strip()[-120:] + ")"
            elif not want_arm and arm:
                ok, msg = False, "GPU-ARM line where the CPU path is expected"
            else:
                for n, (spec, r) in enumerate(zip(cmps, ref)):
                    got, why = oc.compare(mcv.load(o + ("" if n == 0 else f".{n}")), np.asarray(r), spec)
                    msg += f"[{n}] {spec}: {why}  "
                    ok &= got
                if len(cmps) != len(ref):
                    ok, msg = False, f"row has {len(cmps)} comparisons, the op writes {len(ref)} outputs"
                if twin and ok:  # the same row on the CPU path: the twin claim
                    oc_ = o + ".cpu"
                    tc = ours(opn, oc_, paths, [k for k in kvs if k != "gpu=1"])
                    if tc.returncode or "GPU-ARM" in tc.stdout:
                        ok, msg = False, "cpu twin run failed or took the GPU"
                    for n in range(len(ref)):
                        sfx = "" if n == 0 else f".{n}"
                        g, c = mcv.load(o + sfx), mcv.load(oc_ + sfx)
                        dmax = float(np.abs(g.astype(np.float64) - c.astype(np.float64)).max()) if g.shape == c.shape and g.size else -1.0
                        tol = 1e-6 if g.dtype == np.float32 else 0.0
                        good = g.shape == c.shape and g.dtype == c.dtype and 0 <= dmax <= tol
                        msg += f"[{n}] gpu vs cpu maxdiff {dmax:g} (tol {tol:g})  "
                        ok &= good
        except Exception as e:  # a harness bug must not read as a pass
            ok, msg = False, f"harness error: {e!r}"
        print(("PASS" if ok else "FAIL"), cid, "-", ("arm=GPU " if arm else "arm=CPU ") + msg.strip(), flush=True)
        npass += ok
        nfail += not ok
    print(f"rows: {npass + nfail}  pass: {npass}  fail: {nfail}")
    sys.exit(1 if nfail or not npass else 0)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["prep"]:
        prep()
    elif a[:1] == ["h2"]:
        h2()
    elif a[:1] == ["rows"]:
        rows_run([x for x in a[1:] if not x.startswith("--")], "--no-arm" in a)
    else:
        print(__doc__)
        sys.exit(2)
