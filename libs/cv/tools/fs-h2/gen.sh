#!/usr/bin/env bash
# H2 fixture generator (fs-h2). Deterministic: seeded RNG, fixed fonts, PIL/numpy only.
# Writes tests/fixtures/fs-h2/{stream,dialogs,mattes}/ and SHA256SUMS. Never reads private captures.
set -euo pipefail
CV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="${F:-$CV/tests/fixtures/fs-h2}"
mkdir -p "$F/stream" "$F/dialogs" "$F/mattes"
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
python3 -I - "$F" <<'PY' || FAIL gen "python step failed"
import sys, os, json, hashlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import PIL

F = sys.argv[1]
rng = np.random.default_rng(20261123)

def sha(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()

def font(size):
    for p in ['/usr/share/fonts/noto/NotoSans-Regular.ttf', '/usr/share/fonts/TTF/DejaVuSans.ttf']:
        if os.path.exists(p):
            return ImageFont.truetype(p, size), p
    return ImageFont.load_default(size=size), 'PIL-default'

# ---------- 1. stream frame pairs: one changed 64 px tile + JPEG sweep ----------
H, W, T = 448, 640, 64
yy, xx = np.mgrid[0:H, 0:W]
base = np.stack([xx * 255 // W, yy * 255 // H, (xx + yy) % 256], -1)
A = np.clip(base + rng.integers(0, 40, (H, W, 3)), 0, 255).astype(np.uint8)
B = A.copy()
col, row = 3, 2
x0, y0 = col * T, row * T
B[y0:y0 + T, x0:x0 + T] = rng.integers(0, 256, (T, T, 3), dtype=np.uint8)
diff = np.any(A != B, axis=-1)
ys, xs = np.nonzero(diff)
bbox = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]
assert bbox == [x0, y0, x0 + T, y0 + T], bbox  # the changed region is exactly the tile
pairs = {'tile': {'col': col, 'row': row, 'box_xyxy': bbox, 'grid_px': T},
         'frames': {}, 'jpeg': [], 'pil': PIL.__version__}
Image.fromarray(A).save(f'{F}/stream/A.png')
Image.fromarray(B).save(f'{F}/stream/B_changed_tile.png')
Image.fromarray(A).save(f'{F}/stream/C_same.png')  # zero-change control
pairs['lossless_diff_px'] = int(diff.sum())
for q in [95, 85, 75, 50, 30]:
    for name, arr in [('A', A), ('B', B)]:
        p = f'{F}/stream/{name}_q{q}.jpg'
        Image.fromarray(arr).save(p, format='JPEG', quality=q, subsampling=2)  # 4:2:0
        dec = np.asarray(Image.open(p).convert('RGB')).astype(float)  # CPU decode only
        mse = float(np.mean((dec - arr.astype(float)) ** 2))
        psnr = 99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse)
        pairs['jpeg'].append({'file': f'stream/{name}_q{q}.jpg', 'quality': q, 'subsampling': '4:2:0',
                              'psnr_vs_source': round(float(psnr), 2)})
for n in ['A.png', 'B_changed_tile.png', 'C_same.png']:
    pairs['frames'][f'stream/{n}'] = {'sha256': sha(f'{F}/stream/{n}'), 'size': [W, H]}
json.dump(pairs, open(f'{F}/stream/pairs.json', 'w'), indent=1, sort_keys=True)

# ---------- 2. imkit-style dialogs with exact known boxes and text ----------
DIALOGS = [
    {'name': 'dlg_de_light', 'size': (560, 260), 'size_px': 26, 'theme': 'light',
     'title': 'Änderungen speichern?',
     'body': ['Die Datei wurde geändert.', 'Möchten Sie sie speichern?'],
     'buttons': ['Speichern', 'Verwerfen', 'Abbrechen']},
    {'name': 'dlg_en_dark', 'size': (640, 300), 'size_px': 24, 'theme': 'dark',
     'title': 'Delete 3 items?',
     'body': ['This cannot be undone.', 'Files will be removed permanently.'],
     'buttons': ['Delete', 'Cancel']},
    {'name': 'dlg_small_light', 'size': (420, 200), 'size_px': 18, 'theme': 'light',
     'title': 'Übernehmen',
     'body': ['Größe 42 ausgewählt'],
     'buttons': ['OK']},
]
dlg_meta = {}
for d in DIALOGS:
    w, h = d['size']
    dark = d['theme'] == 'dark'
    bg, fg = ((32, 36, 44), (235, 238, 242)) if dark else ((246, 246, 244), (20, 22, 26))
    bar = (48, 54, 66) if dark else (222, 224, 230)
    btn = (70, 78, 92) if dark else (255, 255, 255)
    img = Image.new('RGB', (w, h), bg)
    dr = ImageDraw.Draw(img)
    f, fpath = font(d['size_px'])
    elems = []
    def rec(role, text, box, clickable=False):
        elems.append({'role': role, 'text': text, 'box_xyxy': [int(round(v)) for v in box], 'clickable': clickable})
    bar_h = int(d['size_px'] * 2.2)
    dr.rectangle([0, 0, w - 1, bar_h], fill=bar)
    rec('titlebar', '', [0, 0, w, bar_h])
    ty = (bar_h - d['size_px']) // 2
    tb = dr.textbbox((16, ty), d['title'], font=f)
    dr.text((16, ty), d['title'], font=f, fill=fg)
    rec('title', d['title'], tb)
    y = bar_h + 20
    for line in d['body']:
        bb = dr.textbbox((20, y), line, font=f)
        dr.text((20, y), line, font=f, fill=fg)
        rec('text', line, bb)
        y = bb[3] + 10
    bh = int(d['size_px'] * 2.0)
    bx = w - 20
    for label in reversed(d['buttons']):
        tw = dr.textlength(label, font=f)
        bwid = max(int(d['size_px'] * 5.5), int(tw) + 28)
        x1 = bx
        x0b = x1 - bwid
        y0b, y1b = h - 20 - bh, h - 20
        dr.rounded_rectangle([x0b, y0b, x1, y1b], radius=6, fill=btn, outline=(120, 126, 140))
        tx = x0b + (bwid - tw) / 2
        ly = y0b + (bh - d['size_px']) / 2
        dr.text((tx, ly), label, font=f, fill=fg)
        rec('button', label, [x0b, y0b, x1, y1b], clickable=True)
        bx = x0b - 12
    p = f'{F}/dialogs/{d["name"]}.png'
    img.save(p)
    dlg_meta[d['name']] = {'png': f'dialogs/{d["name"]}.png', 'sha256': sha(p), 'size': [w, h],
                           'font': fpath, 'elements': elems}
json.dump(dlg_meta, open(f'{F}/dialogs/dialogs.json', 'w'), indent=1, ensure_ascii=False, sort_keys=True)

# ---------- 3. mask-labelled mattes: thin boundaries, empty cloth ----------
S = 512
def canvas(seed):
    r = np.random.default_rng(seed)
    gy, gx = np.mgrid[0:S, 0:S]
    bg = np.stack([60 + gx * 80 // S, 70 + gy * 60 // S, 90 + (gx ^ gy) % 24], -1)
    return np.clip(bg + r.integers(-12, 13, (S, S, 3)), 0, 255).astype(np.uint8)

def cloth_texture(seed, base_rgb):
    r = np.random.default_rng(seed)
    t = np.array(base_rgb, float) + r.normal(0, 9, (S, S, 1))
    return np.clip(t, 0, 255).astype(np.uint8)

def poly_mask(polys):
    m = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(m)
    for p in polys:
        d.polygon(p, fill=255)
    return np.asarray(m) > 0

def boundary_band(lab, width=2):
    band = np.zeros(lab.shape, bool)
    for dy in range(-width, width + 1):
        for dx in range(-width, width + 1):
            band |= np.roll(np.roll(lab, dy, 0), dx, 1) != lab
    return band

shirt = [(140, 90), (210, 70), (260, 110), (300, 70), (370, 90), (420, 170), (380, 200), (360, 170),
         (360, 430), (152, 430), (152, 170), (132, 200), (92, 170)]
pants = [(170, 60), (340, 60), (360, 470), (290, 470), (256, 200), (222, 470), (152, 470)]
jacket = [(120, 80), (200, 60), (256, 120), (312, 60), (392, 80), (440, 250), (410, 262), (380, 170),
          (380, 440), (132, 440), (132, 170), (102, 262), (72, 250)]
HANG = [(256, 30), (256, 60)]  # thin hanger, class 2 (not cloth), always present
cases = [
    ('shirt_thin', shirt, 'cloth', (200, 190, 210)),
    ('pants_gap', pants, 'cloth', (40, 60, 120)),
    ('jacket_sleeves', jacket, 'cloth', (150, 110, 70)),
    ('shirt_lowcontrast', shirt, 'cloth', (96, 104, 118)),
    ('empty_hanger', [], 'empty', None),
    ('empty_bg', [], 'empty', None),
]
mattes = {}
for i, (name, polys, kind, rgb) in enumerate(cases):
    img = canvas(100 + i)
    lab = np.zeros((S, S), np.uint8)
    if kind == 'cloth':
        m = poly_mask([polys])
        img = np.where(m[..., None], cloth_texture(200 + i, rgb), img)
        lab[m] = 1
    hm = Image.new('L', (S, S), 0)
    ImageDraw.Draw(hm).line(HANG, fill=255, width=3)
    hmask = np.asarray(hm) > 0
    img = np.where(hmask[..., None], np.array([230, 230, 230], np.uint8), img)
    lab[hmask] = 2
    Image.fromarray(img).save(f'{F}/mattes/{name}.png')
    Image.fromarray(lab, mode='L').save(f'{F}/mattes/{name}.mask.png')
    band = boundary_band(lab, 2)
    counts = {str(k): int(v) for k, v in zip(*np.unique(lab, return_counts=True))}
    mattes[name] = {
        'image': f'mattes/{name}.png', 'mask': f'mattes/{name}.mask.png',
        'labels': {'0': 'background', '1': 'cloth', '2': 'hanger'},
        'kind': kind, 'empty_cloth': kind == 'empty', 'pixel_counts': counts,
        'boundary_band_px_2': int(band.sum()),
        'image_sha256': sha(f'{F}/mattes/{name}.png'), 'mask_sha256': sha(f'{F}/mattes/{name}.mask.png'),
        'size': [S, S]}
json.dump(mattes, open(f'{F}/mattes/mattes.json', 'w'), indent=1, sort_keys=True)

# ---------- hashes ----------
rows = []
for root, _, files in os.walk(F):
    for fn in files:
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, F)
        if rel == 'SHA256SUMS':
            continue
        rows.append(f'{sha(p)}  {rel}')
open(f'{F}/SHA256SUMS', 'w').write('\n'.join(sorted(rows)) + '\n')
print('wrote', len(rows), 'files')
PY
cd "$F" && sha256sum -c --quiet SHA256SUMS && echo "PASS fs-h2 fixtures: $(wc -l < SHA256SUMS) files hashed"
