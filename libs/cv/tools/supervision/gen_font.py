"""Oracle for the font parser rows (tests/cases/font_ttf.txt): fontTools reads cv2's built-in "sans" face
(tools/gen_font_blob.py) and states what supervision._cv.font.ttf must return.

ops: cmap (codepoint -> glyph id), hmetrics ((advance, lsb) from hmtx, default instance), vmetrics (hhea),
     shape (outline of one glyph: sorted unique on-curve endpoints, off-curve controls, bbox) at an optional wght.
The shape rows compare sets, not sequences: stbtt starts a contour at a different point than fontTools and rounds
implied on-curve midpoints with >>1, so composites and variation instances carry tol abs 1 (stbtt's integer delta pipeline).

Run: .work/oracle-venv/bin/python -I tools/gen_font.py
"""
import gzip
import io
import sys

sys.path.insert(0, "tools")
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

from oracle import write_rows

GZ = "src/supervision/_cv/font/Rubik-sans.ttf.gz"
base = TTFont(io.BytesIO(gzip.open(GZ).read()))
order = base.getGlyphOrder()
glyf = base["glyf"]
WGHTS = [None]


def instance(wght):
    if wght is None:
        return base
    return instancer.instantiateVariableFont(TTFont(io.BytesIO(gzip.open(GZ).read())), {"wght": wght}, inplace=False)


def outline(font, gid):
    g = font["glyf"]
    gl = g[order[gid]]
    if gl.numberOfContours == 0:
        return {"ends": [], "ctrl": [], "box": [0, 0, 0, 0]}
    coords, end_pts, flags = gl.getCoordinates(g)
    ends, ctrl = set(), set()
    start = 0
    for e in end_pts:
        pts = [(round(x), round(y), bool(f & 1)) for (x, y), f in zip(coords[start : e + 1], flags[start : e + 1])]
        start = e + 1
        for i, (x, y, on) in enumerate(pts):
            nx, ny, non = pts[(i + 1) % len(pts)]
            if on:
                ends.add((x, y))
            else:
                ctrl.add((x, y))
                if not non:
                    ends.add(((x + nx) >> 1, (y + ny) >> 1))
    box = [gl.xMin, gl.yMin, gl.xMax, gl.yMax] if hasattr(gl, "xMin") else [0, 0, 0, 0]
    return {"ends": [list(p) for p in sorted(ends)], "ctrl": [list(p) for p in sorted(ctrl)], "box": box}


rows = []
cmap = base.getBestCmap()
rows.append(("cmap", {"cps": list(range(0, 128))}, [base.getGlyphID(cmap[c]) if c in cmap else 0 for c in range(0, 128)]))
rows.append(("cmap", {"cps": list(range(128, 700)) + [0x20AC, 0x2022, 0x4E2D, 0x10000, 0xFFFD]},
             [base.getGlyphID(cmap[c]) if c in cmap else 0 for c in list(range(128, 700)) + [0x20AC, 0x2022, 0x4E2D, 0x10000, 0xFFFD]]))
hm = base["hmtx"]
n = len(order)
rows.append(("hmetrics", {"gids": list(range(n))}, [list(hm[order[g]]) for g in range(n)]))
h = base["hhea"]
rows.append(("vmetrics", {}, [h.ascent, h.descent, h.lineGap]))

ascii_gids = [base.getGlyphID(cmap[c]) for c in range(32, 127)]
composites = [g for g in range(n) if glyf[order[g]].isComposite()]
simple = [g for g in range(0, n, 7) if not glyf[order[g]].isComposite()]
for g in sorted(set(ascii_gids + simple[:60])):
    rows.append(("shape", {"gid": g, "wght": None}, outline(base, g)))
for g in composites[:80:2]:
    rows.append(("shape", {"gid": g, "wght": None, "tol": {"abs": 1, "rel": 0}}, outline(base, g)))

write_rows("tests/cases/font_ttf.txt", "gen_font", 0, rows)
