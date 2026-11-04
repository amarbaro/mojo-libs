# supervision/_cv: the cv2 layer

supervision calls cv2 through `supervision._cv2`; this package is the Mojo side. Built on mojo-cv, verified pixel-for-pixel
against cv2 5.0.0.93 by `tests/cases/pixels_cv.txt` (driver `tests/s5/pixels_cv.mojo`, binary `build/pixels_cv`).

| file | ops |
|---|---|
| `draw.mojo` | circle (thin, thick, filled), ellipse and arcs, polylines, fillPoly; LINE_8 only (no LINE_AA, no drawMarker) |
| `ops.mojo` | addWeighted, convertScaleAbs, applyColorMap(JET) on uint8 |
| `png.mojo` | PNG read/write, 8-bit gray/RGB/RGBA/palette, no interlace, no 16-bit, no JPEG; zlib via mojo-gzip |
| `sintable.mojo`, `jet.mojo` | data: cv2's float32 degree sine table (from drawing.cpp), JET LUT (tools/gen_jet.py) |

## TODO: text (putText, getTextSize), a separate item

cv2 5.x does not draw `FONT_HERSHEY_SIMPLEX` with Hershey strokes any more. `modules/imgproc/src/drawing_text.cpp` maps it
(`hersheyToTruetype`) to an embedded gzipped TrueType face ("sans", size `round(100*scale/3.7)`, weight 400 or 600 by
thickness) and renders it through HarfBuzz; `getTextSize` returns that layout's box (`"Hello 123"`, scale 0.9, thickness 2
gives `((117, 24), 1)` on the oracle). There is no glyph table to port. Parity needs the font blob (it sits gzipped in the
cv2 binary), a TrueType parser, a variable-weight instance, an anti-aliasing rasterizer and HarfBuzz-compatible advances.
Rows `cv_put_text_aa`, `cv_text_size` and `pixel_label` wait for it; the driver prints `{"error": "descoped"}` for them.

## Known gaps

- `ThickLine` clips lines that leave the image only for shift 0 (as cv2); polylines with points far outside are untested.
- `fillPoly` takes no offset and uses shift 0.
