#!/usr/bin/env bash
# fs-h2 extension (R3a absdiff, R3b resize, R4 stream front end). Deterministic: seeded RNG, PIL + numpy only.
# Adds tests/fixtures/fs-h2/stream/{B_px16,B_border16}.png, stream/absdiff_ref.json, stream/absdiff_twin.json,
# stream/absdiff_A_vs_B_changed_tile.png, resize/ and re-hashes the whole fixture tree into SHA256SUMS.
# Run after gen.sh. The P0 SHA256SUMS must verify before anything is written.
set -euo pipefail
CV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="${F:-$CV/tests/fixtures/fs-h2}"
FAIL() { echo "FAIL $1: $2" >&2; exit 1; }
[ -f "$F/SHA256SUMS" ] || FAIL refs "missing P0 SHA256SUMS in $F"
(cd "$F" && sha256sum -c --quiet SHA256SUMS) || FAIL refs "P0 fixtures do not verify before extension"
mkdir -p "$F/stream" "$F/resize"
python3 -I - "$F" <<'PY' || FAIL refs "python step failed"
import sys, os, json, hashlib
import numpy as np
from PIL import Image
import PIL

F = sys.argv[1]
THRESH = 16  # frozen dirty threshold: max over channels and pixels of |a-b| per tile
H, W = 448, 640

def sha(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()

def load(rel):
    return np.asarray(Image.open(f'{F}/{rel}').convert('RGB'))

A = load('stream/A.png')
assert A.shape == (H, W, 3), A.shape

def with_block(src, box, seed):
    x0, y0, x1, y1 = box
    out = src.copy()
    out[y0:y1, x0:x1] = np.random.default_rng(seed).integers(0, 256, (y1 - y0, x1 - x0, 3), dtype=np.uint8)
    d = np.any(src != out, axis=-1)
    assert d.any(), 'block did not change the frame'
    ys, xs = np.nonzero(d)
    bb = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]
    assert bb == list(box), (bb, box)  # the changed region is exactly the block
    return out

B16 = with_block(A, (336, 256, 352, 272), 20261124 + 1)     # 16 px cell (col 21, row 16), interior
BB16 = with_block(A, (624, 432, 640, 448), 20261124 + 2)    # 16 px cell (col 39, row 27), bottom-right border
Image.fromarray(B16).save(f'{F}/stream/B_px16.png')
Image.fromarray(BB16).save(f'{F}/stream/B_border16.png')

def dirty(d2, t):
    m = d2.reshape(H // t, t, W // t, t).max(axis=(1, 3))
    return [[int(r), int(c)] for r, c in zip(*np.nonzero(m > THRESH))], m

def absdiff2(x, y):
    return np.abs(x.astype(np.int16) - y.astype(np.int16)).max(axis=2).astype(np.uint8)

ref = {'threshold': THRESH, 'rule': 'tile dirty iff max over channels and pixels of |a-b| > threshold',
       'grids_px': [64, 16], 'size': [W, H], 'pil': PIL.__version__, 'pairs': {}}
cases = [
    ('A_vs_B_changed_tile', A, load('stream/B_changed_tile.png')),
    ('A_vs_B_px16', A, B16),
    ('A_vs_B_border16', A, BB16),
    ('A_vs_C_same', A, load('stream/C_same.png')),
]
for q in [95, 85, 75, 50, 30]:  # JPEG sweep vs the lossless source (CPU PIL decode only)
    cases.append((f'A_vs_A_q{q}', A, load(f'stream/A_q{q}.jpg')))
for name, x, y in cases:
    d2 = absdiff2(x, y)
    d64, m64 = dirty(d2, 64)
    d16, _ = dirty(d2, 16)
    ref['pairs'][name] = {'max_abs_diff': int(d2.max()), 'nonzero_px': int((d2 > 0).sum()),
                          'dirty_tiles_64': d64, 'dirty_tiles_16': d16, 'tile_max_64': m64.tolist()}
    if name == 'A_vs_B_changed_tile':
        out = f'{F}/stream/absdiff_A_vs_B_changed_tile.png'
        Image.fromarray(d2, mode='L').save(out)
        ref['pairs'][name]['absdiff_png_sha256'] = sha(out)
# frozen expectations: a regeneration that drifts fails loudly
assert ref['pairs']['A_vs_B_changed_tile']['dirty_tiles_64'] == [[2, 3]]
assert ref['pairs']['A_vs_B_px16']['dirty_tiles_16'] == [[16, 21]]
assert ref['pairs']['A_vs_B_border16']['dirty_tiles_16'] == [[27, 39]]
assert ref['pairs']['A_vs_C_same']['dirty_tiles_16'] == []
json.dump(ref, open(f'{F}/stream/absdiff_ref.json', 'w'), indent=1, sort_keys=True)

# R3b resize references: PIL BILINEAR, reducing_gap=None. Float twin: tolerance is set by S2 from measurement.
rs = {'method': 'PIL Image.resize BILINEAR, reducing_gap=None', 'pil': PIL.__version__, 'kind': 'float', 'cases': []}
for src_name, src, dims in [
    ('A', A, (320, 224)), ('A', A, (400, 280)), ('A', A, (1280, 896)),
    ('B_changed_tile', load('stream/B_changed_tile.png'), (400, 280)),
]:
    im = Image.fromarray(src).resize(dims, Image.BILINEAR, reducing_gap=None)
    out = f'{F}/resize/{src_name}_{dims[0]}x{dims[1]}_bilinear.png'
    im.save(out)
    rs['cases'].append({'file': f'resize/{os.path.basename(out)}', 'source': src_name, 'size': list(dims),
                        'raw_rgb_sha256': hashlib.sha256(np.ascontiguousarray(np.asarray(im)).tobytes()).hexdigest(),
                        'png_sha256': sha(out)})
json.dump(rs, open(f'{F}/resize/resize_ref.json', 'w'), indent=1, sort_keys=True)

# absdiff integer twin: exact bytes, no tolerance
ab = {'kind': 'integer', 'op': 'absdiff', 'dtype': 'uint8', 'exact': True,
      'frames': ['stream/A.png', 'stream/B_changed_tile.png', 'stream/B_px16.png', 'stream/B_border16.png']}
json.dump(ab, open(f'{F}/stream/absdiff_twin.json', 'w'), indent=1, sort_keys=True)
print('refs written')
PY

# re-hash the whole tree (SHA256SUMS excluded); P0 entries must be unchanged
python3 -I - "$F" <<'PY' || FAIL refs "hash step failed"
import sys, os, hashlib
F = sys.argv[1]
rows = []
for root, _, files in os.walk(F):
    for fn in files:
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, F)
        if rel == 'SHA256SUMS':
            continue
        rows.append(f"{hashlib.sha256(open(p, 'rb').read()).hexdigest()}  {rel}")
open(f'{F}/SHA256SUMS', 'w').write('\n'.join(sorted(rows)) + '\n')
print('hashed', len(rows), 'files')
PY
cd "$F" && sha256sum -c --quiet SHA256SUMS && echo "PASS fs-h2 refs: $(wc -l < SHA256SUMS) files hashed"
