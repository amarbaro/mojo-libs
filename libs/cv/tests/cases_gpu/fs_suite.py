"""fs-stream and fs-gpu2 rows (full-stack P1: R4, R3a, R3b). tools/oracle_cv2.py has no stream op and another owner, so this
runner adds the numpy oracle of src/mojocv/stream.mojo to oracle_cv2.OPS and runs the rows of tests/cases/fs-*.txt itself.

  fs_suite.py prep                     decode the fs-h2 frames into tests/fixtures/fs2_*.mcv (CPU decoders only: magick, cv2)
  fs_suite.py h2                       our tile masks and GPU absdiff against the fs-h2 references (absdiff_ref.json, absdiff twin PNG)
  fs_suite.py r7                       R7 dense features: the falsifier's preconditions (BLOCK, exit 3, while the nine hand photos or R6 are missing)
  fs_suite.py rows [--no-arm] CASES..  run rows: ours (MCV_BIN, default .bin/mojo-cv) against the oracle with the row's comparison
A gpu=1 row is also run without gpu=1: the GPU output must equal it byte for byte (float32 outputs: within 1e-6).
A row with gpu=1 must print `GPU-ARM` (the GPU kernel ran); a row id starting `fb_` must not (a parameter the kernels do not
cover: the CPU answer, reported). --no-arm (no accelerator visible) requires the marker absent on every row.
Exit 0 all pass, 1 a failure, 3 a missing precondition (prints a BLOCK line).

Full-stack P2 (R13, R20a, R3c): `prep3` decodes the fs-h2 p2 fixtures (stuck pairs, dialog, planted EVM clip) into tests/fixtures/fs3_*.mcv
and builds the controls (blank screen, occluded button); `rows` also takes tests/cases/fs-screen.txt and tests/cases_gpu/fs-evm.txt.
Rows whose op is screenParse, screenStuck, evmChain or evmGain are judged here (CUSTOM below) against the labelled truth in p2.json."""
import glob, json, math, os, subprocess, sys, unicodedata
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


# ---- P2: screen parser, stuck check, EVM twin -------------------------------------------------------------------------
P2 = os.path.join(H2, "p2")
ROLE = {"panel": 0, "dialog": 1, "button": 2, "text": 3}
FONT = "/usr/share/fonts/noto/NotoSans-Regular.ttf"


def p2json():
    f = os.path.join(P2, "p2.json")
    if not os.path.isfile(f):
        block(f"fs-h2 p2 fixtures missing under {P2} (set FS_H2 to a tree holding p2/: lane fs/p2-h2, commit 66f57013)")
    return json.load(open(f))


def prep3():
    p2json()
    r = subprocess.run(["sha256sum", "-c", "--quiet", "SHA256SUMS"], cwd=P2, capture_output=True, text=True)
    if r.returncode:
        print("FAIL prep3: p2 SHA256SUMS does not verify: " + r.stdout[:200])
        sys.exit(1)
    os.makedirs(FIX, exist_ok=True)
    names = {n: os.path.join(P2, "stuck", n + ".png") for n in ("modal_A", "modal_B", "video_A", "video_B", "cursor_A", "cursor_B")}
    for k, f in names.items():
        subprocess.run([os.path.join(ROOT, "scripts", "img2mcv.sh"), f, os.path.join(FIX, f"fs3_{k}.mcv"), "bgr"], check=True)
    a = mcv.load(os.path.join(FIX, "fs3_modal_A.mcv"))
    t = p2json()["stuck"]["modal_over_changing_bg"]["elements"]
    ok = [e for e in t if e["text"] == "OK"][0]["box_xyxy"]
    occ = a.copy()  # the OK button covered by the dialog's own white: an occluded button
    occ[ok[1]:ok[3] + 2, ok[0]:ok[2] + 2] = 255
    mcv.save(occ, os.path.join(FIX, "fs3_modal_occ.mcv"))
    mcv.save(np.full((320, 480, 3), (250, 245, 245), np.uint8), os.path.join(FIX, "fs3_blank.mcv"))  # a blank screen
    for k, f in (("sin", "planted_sin"), ("static", "static")):  # T,H,W uint8 -> H,W,T float32 (frames as channels)
        x = np.load(os.path.join(P2, "evm", f + ".npy")).astype(np.float32)
        mcv.save(np.ascontiguousarray(np.transpose(x, (1, 2, 0))), os.path.join(FIX, f"fs3_evm_{k}.mcv"))
    print("PASS prep3: 6 stuck frames, occluded, blank, 2 EVM clips from " + P2)


def box_iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    i = ix * iy
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u else 0.0


def pil_text(text, size, clip_right, origin_x):
    """Ink box of `text` drawn at the font's origin and the count of characters whose advance ends inside `clip_right`,
    from PIL's metrics (system python3: the oracle for the clipped body line of modal_A)."""
    code = ("import json;from PIL import ImageFont;f=ImageFont.truetype(%r,%d);t=%r;n=0\n"
            "for k in range(len(t)+1):\n    n=k if f.getlength(t[:k])+%d<=%d else n\n"
            "print(json.dumps([list(f.getbbox(t)),n]))" % (FONT, size, text, origin_x, clip_right))
    r = subprocess.run(["python3", "-I", "-c", code], capture_output=True, text=True)
    if r.returncode:
        block("PIL (system python3) or " + FONT + " missing: " + r.stderr[-120:])
    return json.loads(r.stdout)


def modal_truth(drop_ok=False):
    """The labelled elements of modal_A as exclusive boxes. The fixture's own boxes are PIL's inclusive rectangles (+1 each side);
    the body line is the one fixture defect: its text is 255 px wide inside a dialog whose inner edge is 359, so only the part
    that fits (advance <= 359) lies on the dialog. Its box is PIL's ink box clipped to the dialog, its text is the visible prefix
    minus the last character (that glyph straddles the border and is overpainted)."""
    t = p2json()["stuck"]["modal_over_changing_bg"]
    dlg = t["dialog_box_xyxy"]
    out = []
    for e in t["elements"]:
        b = list(e["box_xyxy"])
        d = dict(role=ROLE[e["role"]], text=e["text"], click=int(e["clickable"]), n=None)
        if e["role"] == "text":
            bb, n = pil_text(e["text"], 14, dlg[2] - 1, b[0])
            b = [b[0] + bb[0], b[1] + bb[1], min(b[0] + bb[2], dlg[2] + 1), b[1] + bb[3]]
            d["n"] = n - 1
        else:
            b = [b[0], b[1], b[2] + 1, b[3] + 1]
        if drop_ok and e["text"] == "OK":
            continue
        d["box"] = b
        out.append(d)
    return out


SCREEN_TRUTH = {"fs3_modal_A": lambda: modal_truth(), "fs3_modal_B": lambda: modal_truth(), "fs3_modal_occ": lambda: modal_truth(True),
                "fs3_blank": lambda: [], "fs3_cursor_A": lambda: None}


def read_elems(o):
    tb, tx = mcv.load(o), mcv.load(o + ".1")
    tb = tb.reshape(-1, 6)
    if not len(tb):
        return []
    tx = tx.reshape(len(tb), -1)
    return [dict(box=list(map(int, r[:4])), role=int(r[4]), click=int(r[5]), text=unicodedata.normalize("NFC", bytes(x).split(b"\0")[0].decode("utf-8", "replace")).strip()) for r, x in zip(tb, tx)]


def elems_score(spec, ours, truth):
    k, _, arg = spec.partition(":")
    if k == "empty":
        return not ours, f"{len(ours)} elements"
    if k == "none":  # none:12 = no element of role 1 or 2 (dialog, button)
        bad = [e for e in ours if str(e["role"]) in arg]
        return not bad, f"{len(bad)} of roles {arg}"
    if truth is None:
        return False, "no labelled truth for this picture"
    match = []
    for t in truth:
        ious = [box_iou(t["box"], e["box"]) for e in ours]
        j = int(np.argmax(ious)) if ious else -1
        match.append((j, ious[j] if j >= 0 else 0.0))
    if k == "box":
        lo = min([m[1] for m in match], default=1.0)
        return lo >= float(arg), f"min iou {lo:.4f} over {len(truth)} labelled (want {arg})"
    if k == "role":
        bad = [t["text"] for t, m in zip(truth, match) if m[0] < 0 or ours[m[0]]["role"] != t["role"]]
        return not bad, f"{len(truth) - len(bad)}/{len(truth)} roles right" + (f", wrong: {bad}" if bad else "")
    if k == "click":
        bad = [t["text"] for t, m in zip(truth, match) if m[0] < 0 or ours[m[0]]["click"] != t["click"]]
        return not bad, f"{len(truth) - len(bad)}/{len(truth)} clickable flags right"
    if k == "text":
        bad = []
        for t, m in zip(truth, match):
            g = ours[m[0]]["text"] if m[0] >= 0 else ""
            w = unicodedata.normalize("NFC", t["text"])
            if t["n"] is not None:
                g, w = g[:t["n"]], w[:t["n"]]
            if g != w:
                bad.append((w, g))
        return not bad, f"{len(truth) - len(bad)}/{len(truth)} texts equal" + (f", differ: {bad}" if bad else "")
    if k == "extra":
        used = {m[0] for m in match if m[1] >= 0.5}
        n = sum(1 for i, e in enumerate(ours) if i not in used and max([box_iou(t["box"], e["box"]) for t in truth] or [0]) < 0.5)
        return n <= int(arg), f"{n} unmatched elements (allowed {arg})"
    raise ValueError("unknown elems spec " + spec)


def c_screenParse(cid, opn, ins, paths, kv, cmps, o, no_arm):
    t = ours(opn, o, paths, [f"{k}={v}" for k, v in kv.items()])
    if t.returncode:
        return False, "ours failed: " + (t.stdout + t.stderr).strip()[-300:], False
    truth = SCREEN_TRUTH[ins[0]]()
    es = read_elems(o)
    ok, msg = True, ""
    for c in cmps:
        g, why = elems_score(c.removeprefix("elems:"), es, truth)
        ok &= g
        msg += f"[{c}] {why}  "
    return ok, msg, False


STUCK = {"fs3_modal_A": "modal_over_changing_bg", "fs3_video_A": "playing_video", "fs3_cursor_A": "blinking_cursor"}


def c_screenStuck(cid, opn, ins, paths, kv, cmps, o, no_arm):
    t = ours(opn, o, paths, [f"{k}={v}" for k, v in kv.items()])
    if t.returncode:
        return False, "ours failed: " + (t.stdout + t.stderr).strip()[-300:], False
    tr = p2json()["stuck"][STUCK[ins[0]]]
    flags, bbox, dlg = (mcv.load(o + s).ravel().tolist() for s in ("", ".1", ".2"))
    ok, msg = True, ""
    for c in cmps:
        if c == "stuck:flags":  # [progress, stuck] against the labelled expectation
            want = [int(tr["expect_progress"]), int(tr["expect_dialog_stuck"])]
            g, why = flags == want, f"ours {flags} want {want}"
        elif c == "stuck:bbox":  # the changed bounding box, recomputed from the two PNGs by numpy at the row's threshold
            a, b = (mcv.load(p).astype(int) for p in paths)
            ch = np.abs(a - b).max(axis=2) > int(kv.get("thr", 16))
            ys, xs = np.nonzero(ch)
            want = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1] if len(xs) else [0, 0, 0, 0]
            g, why = bbox == want and (want == tr["changed_bbox_xyxy"] or int(kv.get("thr", 16)) != 16), f"ours {bbox} numpy {want} labelled {tr['changed_bbox_xyxy']}"
        elif c.startswith("stuck:dialog"):
            want_box = tr.get("dialog_box_xyxy")
            if want_box is None:
                g, why = dlg[0] == 0, f"no dialog labelled, ours found={dlg[0]}"
            else:
                wb = [want_box[0], want_box[1], want_box[2] + 1, want_box[3] + 1]
                iou = box_iou(dlg[1:5], wb) if dlg[0] else 0.0
                g, why = dlg[0] == 1 and iou >= float(c.split(":")[2]) and dlg[5] == tr["dialog_changed_px"], f"found={dlg[0]} iou {iou:.4f} changed inside {dlg[5]} (labelled {tr['dialog_changed_px']})"
        else:
            raise ValueError("unknown stuck spec " + c)
        ok &= g
        msg += f"[{c}] {why}  "
    return ok, msg, False


def c_evmChain(cid, opn, ins, paths, kv, cmps, o, no_arm):
    """T calls of evmStep (the state in a file between them) equal one evm call on the T frames, bytewise; both within the
    numpy oracle's tolerance. With gpu=1 every step must print GPU-ARM."""
    x = mcv.load(paths[0])
    kvs = [f"{k}={v}" for k, v in kv.items() if k != "gpu"]
    arm = []
    work = os.path.join(os.path.dirname(o), cid + "-chain")
    os.makedirs(work, exist_ok=True)
    cpu_o = o + ".cpu"
    t = ours("evm", cpu_o, paths, kvs)
    if t.returncode:
        return False, "cpu evm failed: " + t.stderr[-200:], False
    batch = mcv.load(cpu_o)
    st, outs = None, []
    for k in range(x.shape[2]):
        fp = os.path.join(work, f"f{k}.mcv")
        mcv.save(np.ascontiguousarray(x[:, :, k]), fp)
        so = os.path.join(work, f"s{k}")
        ins_k = [fp] + ([st] if st else [])
        t = ours("evmStep", so, ins_k, kvs + (["gpu=1"] if kv.get("gpu") == "1" else []))
        if t.returncode:
            return False, f"step {k} failed: " + (t.stdout + t.stderr)[-200:], False
        arm.append("GPU-ARM" in t.stdout)
        outs.append(mcv.load(so))
        st = so + ".1"
    chain = np.stack(outs, axis=2)
    want_arm = kv.get("gpu") == "1" and not no_arm
    if want_arm and not all(arm):
        return False, f"gpu=1 but {arm.count(False)} of {len(arm)} steps printed no GPU-ARM line", any(arm)
    if not want_arm and any(arm):
        return False, "GPU-ARM line where the CPU path is expected", True
    ref = np.asarray(oc.OPS["evm"]([x], kv))
    ok, msg = True, f"{len(arm)} steps  "
    for i, c in enumerate(cmps):
        if i == 0:  # the first comparison is the chain against our own batch call, the rest against numpy
            d = float(np.abs(chain.astype(np.float64) - batch).max())
            g, why = d == 0.0, f"chain vs one batch call maxdiff {d:g}"
        else:
            g, why = oc.compare(chain, ref, c)
            why = "chain vs numpy: " + why
        ok &= g
        msg += f"[{c}] {why}  "
    return ok, msg, any(arm)


def c_evmGain(cid, opn, ins, paths, kv, cmps, o, no_arm):
    """The planted sinusoid (0.1 cycles per frame, 2 levels in the patch) comes out amplified by the closed-form gain of the two
    first-order low-passes: |1 + alpha (H_hi - H_lo)| at that frequency; amplitudes fitted by least squares over frames 20..39 of
    the patch pixels (median). Tolerance from the row (gain:T = relative)."""
    pj = p2json()["evm"]
    kvs = [f"{k}={v}" for k, v in kv.items()]
    t = ours("evm", o, paths, kvs)
    arm = "GPU-ARM" in t.stdout
    if t.returncode:
        return False, "ours failed: " + (t.stdout + t.stderr)[-200:], arm
    if kv.get("gpu") == "1" and not no_arm and not arm:
        return False, "gpu=1 but no GPU-ARM line", arm
    x, y = mcv.load(paths[0]), mcv.load(o)
    (r0, r1), (c0, c1) = pj["patch_yx_slices"]
    w = 2 * math.pi * pj["freq_cycles_per_frame"]
    tt = np.arange(20, x.shape[2])
    A = np.stack([np.cos(w * tt), np.sin(w * tt), np.ones(len(tt))], 1)

    def amp(v):
        z = v[r0:r1, c0:c1, 20:].reshape(-1, len(tt)).astype(np.float64)
        co = np.linalg.lstsq(A, z.T, rcond=None)[0]
        return float(np.median(np.hypot(co[0], co[1])))

    al, lo, hi = float(kv.get("alpha", 20)), float(kv.get("lo", 0.05)), float(kv.get("hi", 0.4))
    H = lambda a: a / (1 - (1 - a) * np.exp(-1j * w))
    theory = float(abs(1 + al * (H(hi) - H(lo))))
    got = amp(y) / amp(x)
    err = abs(got / theory - 1)
    tol = float(cmps[0].split(":")[1])
    return err <= tol, f"gain {got:.4f} closed form {theory:.4f} relative error {err:.4f} (bar {tol}), input amplitude {amp(x):.3f}", arm


CUSTOM = {"screenParse": c_screenParse, "screenStuck": c_screenStuck, "evmChain": c_evmChain, "evmGain": c_evmGain}


def r7():
    """R7 b (frozen-feature matte): the falsifier comes first, on the planted disc and the nine labelled hand photos, before any upsampler
    (plan 8, unknowns). No dense-feature code exists until it can run, so this is the whole gate: BLOCK with every missing precondition."""
    hands = os.environ.get("FS_HANDS", "/home/mario/Projects/mojo/mojo-libs/.work/fs/labels/hands")
    why = []
    n = len([f for f in os.listdir(hands) if not f.startswith(".")]) if os.path.isdir(hands) else 0
    if n < 18:  # nine photos and nine masks
        why.append(f"nine labelled hand photos (photo + mask each) absent: {hands} holds {n} files")
    zoo = os.path.join(ROOT, "..", "gpunet", "tests", "check_zoo.sh")
    if not os.path.isfile(zoo):
        why.append("R6 not landed in this tree (libs/gpunet/tests/check_zoo.sh missing): no SigLIP patch-token output to test")
    disc = os.path.join(P2, "mattes", "disc.png")
    if not os.path.isfile(disc):
        why.append(f"planted disc fixture missing: {disc}")
    if why:
        block("R7 dense features: " + "; ".join(why))
    block("R7 dense features: preconditions present, the falsifier rows (fs-dense.txt) are not written yet")


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
        if opn in CUSTOM:
            try:
                ok, msg, arm = CUSTOM[opn](cid, opn, ins, paths, kv, cmps, o, no_arm)
            except Exception as e:  # a harness bug must not read as a pass
                ok, msg, arm = False, f"harness error: {e!r}", False
            print(("PASS" if ok else "FAIL"), cid, "-", ("arm=GPU " if arm else "arm=CPU ") + msg.strip(), flush=True)
            npass += ok
            nfail += not ok
            continue
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
    elif a[:1] == ["r7"]:
        r7()
    elif a[:1] == ["prep3"]:
        prep3()
    elif a[:1] == ["rows"]:
        rows_run([x for x in a[1:] if not x.startswith("--")], "--no-arm" in a)
    else:
        print(__doc__)
        sys.exit(2)
