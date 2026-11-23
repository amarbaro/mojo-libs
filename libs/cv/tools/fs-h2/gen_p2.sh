#!/usr/bin/env bash
# fs-h2 P2 fixtures (R13a stuck states, R13b/R20a dialog truth, R7 planted disc, R3c planted EVM signal).
# Deterministic: seeded RNG, PIL 13 + numpy 2.5 only. Writes tests/fixtures/fs-h2/p2/ and p2/SHA256SUMS.
# Never reads private captures. The nine labelled hand photos are NOT generated here (no labels exist; see docs/fs-h2.md).
set -euo pipefail
CV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="${F:-$CV/tests/fixtures/fs-h2}"
P="$F/p2"
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
[ -f "$F/SHA256SUMS" ] || FAIL p2 "missing P0 SHA256SUMS in $F"
(cd "$F" && sha256sum -c --quiet SHA256SUMS) || FAIL p2 "P0 fixtures do not verify before extension"
mkdir -p "$P/stuck" "$P/mattes" "$P/evm"
python3 -I - "$P" <<'PY' || FAIL p2 "python step failed"
import sys, os, json, hashlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import PIL

P = sys.argv[1]
FONT = '/usr/share/fonts/noto/NotoSans-Regular.ttf'
def font(sz):
    return ImageFont.truetype(FONT, sz) if os.path.exists(FONT) else ImageFont.load_default(size=sz)
def save(img, rel):
    img.save(f'{P}/{rel}')
def bbox_of(d):
    ys, xs = np.nonzero(d)
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1] if len(xs) else None

truth = {'pil': PIL.__version__, 'stuck': {}, 'mattes': {}, 'evm': {}}

# ---------- R13a stuck states: modal over a changing background, playing video, blinking cursor ----------
W, H = 480, 320
DIALOG = (120, 100, 360, 220)
BTN_CANCEL = (150, 180, 230, 208)
BTN_OK = (250, 180, 330, 208)
def dialog_frame(bg_shift):
    img = Image.new('RGB', (W, H))
    px = np.zeros((H, W, 3), np.uint8)
    yy, xx = np.mgrid[0:H, 0:W]
    px[..., 0] = ((xx + bg_shift) * 255 // W) % 256
    px[..., 1] = yy * 255 // H
    px[..., 2] = (xx * yy + bg_shift * 7) % 256   # the background changes with bg_shift
    img = Image.fromarray(px)
    d = ImageDraw.Draw(img)
    d.rectangle(DIALOG, fill=(255, 255, 255), outline=(120, 120, 120), width=2)
    d.text((136, 114), 'Änderungen verwerfen?', font=font(18), fill=(20, 20, 20))
    d.text((136, 146), 'Ungespeicherte Daten gehen verloren.', font=font(14), fill=(60, 60, 60))
    d.rectangle(BTN_CANCEL, fill=(235, 235, 235), outline=(90, 90, 90))
    d.text((160, 186), 'Abbrechen', font=font(14), fill=(20, 20, 20))
    d.rectangle(BTN_OK, fill=(40, 90, 200), outline=(20, 50, 120))
    d.text((276, 186), 'OK', font=font(14), fill=(255, 255, 255))
    return img
A = dialog_frame(0); B = dialog_frame(37)
save(A, 'stuck/modal_A.png'); save(B, 'stuck/modal_B.png')
a = np.asarray(A).astype(int); b = np.asarray(B).astype(int)
d = np.any(a != b, axis=-1)
dlg = np.zeros((H, W), bool); x0, y0, x1, y1 = DIALOG; dlg[y0:y1, x0:x1] = True
assert not d[dlg].any(), 'dialog region must be identical across the pair (it is stuck)'
assert d.any(), 'background must change'
assert not (d & dlg).any()
truth['stuck']['modal_over_changing_bg'] = {
    'pair': ['stuck/modal_A.png', 'stuck/modal_B.png'],
    'dialog_box_xyxy': list(DIALOG), 'changed_bbox_xyxy': bbox_of(d),
    'dialog_changed_px': 0, 'expect_dialog_stuck': True, 'expect_progress': False,
    'elements': [
        {'role': 'dialog', 'box_xyxy': list(DIALOG), 'text': 'Änderungen verwerfen?', 'clickable': False},
        {'role': 'text', 'box_xyxy': [136, 146, 344, 162], 'text': 'Ungespeicherte Daten gehen verloren.', 'clickable': False},
        {'role': 'button', 'box_xyxy': list(BTN_CANCEL), 'text': 'Abbrechen', 'clickable': True},
        {'role': 'button', 'box_xyxy': list(BTN_OK), 'text': 'OK', 'clickable': True}]}

# playing video: a whole region changes between frames; this is NOT stuck
VB = (0, 0, 320, 240)
rng = np.random.default_rng(20261123 + 5)
v0 = rng.integers(0, 256, (240, 320, 3), dtype=np.uint8)
v1 = np.roll(v0, 3, axis=1)
vA = np.zeros((H, W, 3), np.uint8); vB = np.zeros((H, W, 3), np.uint8)
vA[:240, :320] = v0; vB[:240, :320] = v1
vA[240:, :] = 200; vB[240:, :] = 200
save(Image.fromarray(vA), 'stuck/video_A.png'); save(Image.fromarray(vB), 'stuck/video_B.png')
dv = np.any(vA.astype(int) != vB.astype(int), axis=-1)
truth['stuck']['playing_video'] = {
    'pair': ['stuck/video_A.png', 'stuck/video_B.png'], 'video_box_xyxy': list(VB),
    'changed_bbox_xyxy': bbox_of(dv), 'expect_dialog_stuck': False, 'expect_progress': True}
assert bbox_of(dv) == [0, 0, 317, 240] or bbox_of(dv)[3] == 240

# blinking cursor in a text field: only the cursor column toggles; this is NOT progress
FIELD = (40, 40, 300, 72)
CUR = (44, 48, 47, 64)   # x0,y0,x1,y1 of the 3 px wide cursor
def field_frame(cursor_on):
    img = Image.new('RGB', (W, H), (245, 245, 250))
    dr = ImageDraw.Draw(img)
    dr.rectangle(FIELD, fill=(255, 255, 255), outline=(140, 140, 140), width=1)
    dr.text((52, 50), 'Suchbegriff', font=font(14), fill=(30, 30, 30))
    if cursor_on:
        dr.rectangle((CUR[0], CUR[1], CUR[2] - 1, CUR[3] - 1), fill=(0, 0, 0))
    return img
cA = field_frame(True); cB = field_frame(False)
save(cA, 'stuck/cursor_A.png'); save(cB, 'stuck/cursor_B.png')
dc = np.any(np.asarray(cA).astype(int) != np.asarray(cB).astype(int), axis=-1)
assert bbox_of(dc) == [CUR[0], CUR[1], CUR[2], CUR[3]], bbox_of(dc)
truth['stuck']['blinking_cursor'] = {
    'pair': ['stuck/cursor_A.png', 'stuck/cursor_B.png'], 'field_box_xyxy': list(FIELD),
    'cursor_box_xyxy': list(CUR), 'changed_bbox_xyxy': bbox_of(dc),
    'expect_dialog_stuck': True, 'expect_progress': False}

# ---------- R7 planted disc and mask-labelled references (labels 0 background, 1 disc, 2 hole rim marker) ----------
S = 256; R = 60; C = 128
yy, xx = np.mgrid[0:S, 0:S]
dist = np.hypot(xx - C + 0.5, yy - C + 0.5)
bg = np.zeros((S, S, 3), np.uint8)
bg[..., 0] = 60 + xx // 8; bg[..., 1] = 90 + yy // 8; bg[..., 2] = 140
def disc_image(inside_rgb, hole):
    img = bg.copy()
    inside = dist <= R
    img[inside] = inside_rgb
    if hole:
        img[118:124, 118:124] = bg[118:124, 118:124]   # a 6x6 planted hole inside the disc
    return img
def disc_mask(hole):
    m = np.zeros((S, S), np.uint8)
    m[dist <= R] = 1
    ring = (dist > R - 2) & (dist <= R)
    m[ring & (dist <= R)] = 1
    if hole:
        m[118:124, 118:124] = 0
    return m
# 2 px boundary band as a separate class for the thin-boundary score: label 2 on the outer 2 px of the disc
def with_band(m):
    out = m.copy()
    band = (dist > R - 2) & (dist <= R)
    out[band] = 2
    return out
variants = {
    'disc': (disc_image((200, 60, 60), False), with_band(disc_mask(False))),
    'disc_hole': (disc_image((200, 60, 60), True), with_band(disc_mask(True))),
    'disc_empty': (bg.copy(), np.zeros((S, S), np.uint8)),
}
mattes = {}
for name, (img, m) in variants.items():
    Image.fromarray(img).save(f'{P}/mattes/{name}.png')
    Image.fromarray(m, mode='L').save(f'{P}/mattes/{name}.mask.png')
    mattes[name] = {
        'image': f'mattes/{name}.png', 'mask': f'mattes/{name}.mask.png',
        'labels': {'0': 'background', '1': 'disc', '2': 'boundary_band_2px'},
        'counts': {str(k): int((m == k).sum()) for k in (0, 1, 2)},
        'bbox_xyxy_disc': bbox_of((m == 1) | (m == 2)), 'empty': bool(not ((m == 1) | (m == 2)).any())}
assert mattes['disc_empty']['empty'] and not mattes['disc']['empty']
truth['mattes'] = {'radius_px': R, 'center_xy': [C, C], 'size': [S, S], 'hole_xyxy': [118, 118, 124, 124], 'items': mattes,
                   'note': 'planted disc, synthetic; R7 falsifier stays BLOCK until the nine labelled hand photos are supplied'}

# ---------- R3c planted EVM signal: 1 gray level sinusoid over 40 frames, static control ----------
T, H2, W2 = 40, 64, 96
rng = np.random.default_rng(20261123 + 9)
base = np.full((T, H2, W2), 128, np.float64)
t = np.arange(T)
freq = 0.1; amp = 2.0
sig = np.round(128 + amp * np.sin(2 * np.pi * freq * t))
patch = (slice(32, 56), slice(24, 40))  # y, x rows of the 16x24 planted patch
planted = np.full((T, H2, W2), 128, np.uint8)
for i in range(T):
    planted[i][patch] = int(sig[i])
static = np.full((T, H2, W2), 128, np.uint8)
np.save(f'{P}/evm/planted_sin.npy', planted); np.save(f'{P}/evm/static.npy', static)
pv = planted[:, patch[0], patch[1]].astype(int)
assert (static == 128).all()
truth['evm'] = {'frames': T, 'size_hw': [H2, W2], 'freq_cycles_per_frame': freq, 'amp_levels': amp,
                'patch_yx_slices': [[32, 56], [24, 40]], 'dtype': 'uint8', 'layout': 'T,H,W',
                'measured_peak_to_peak_in_patch': int(pv.max() - pv.min()),
                'outside_patch_constant': True, 'static_control': 'evm/static.npy (all 128)',
                'note': 'planted signal for R3c gain check; expected gain is measured against the stated amp, not tuned'}
assert truth['evm']['measured_peak_to_peak_in_patch'] in (3, 4, 5)  # round(2 sin) peak to peak

json.dump(truth, open(f'{P}/p2.json', 'w'), indent=1, sort_keys=True, ensure_ascii=False)
PY
cd "$P" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
echo "p2 fixtures: $(wc -l < "$P/SHA256SUMS") files hashed"
