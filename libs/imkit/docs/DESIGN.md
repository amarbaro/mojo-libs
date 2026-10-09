# imkit design

## Frame

```
app frame (GPU) ─────────────────────────────────────────────┐
window.poll ─► Input ─► Ui.begin ─► widgets ─► draw list ──┐ │
                                    (host, every frame)    │ │
Ui.finish: bin commands into 16 x 16 tiles ◄───────────────┘ │
copy cmd + bins + counts ─► compose kernel ─► UW x UH RGBA   │
window.present: scene texture (blend NONE) + UI layer (BLEND)◄┘
```

- **Immediate mode.** A widget is a call that draws and returns its interaction (`button(...) -> Bool`). Identity is
  an Int id the caller gives; hot (under the mouse) and active (pressed, waiting for the release) are the only state.
  A click is press then release on the same widget.
- **One draw list.** Every command is 8 u32 words: kind, x0, y0, x1, y1, r, rgba, aux. Kinds: rounded rect (r =
  radius, aux = soft-shadow blur), glyph (aux = atlas x | y << 16), capsule line (r = half width), triangle (either
  winding). At most NCMD = 4096 commands.
- **Tiles.** The host bins commands into 16 x 16 pixel tiles (TCAP = 64 per tile; more are dropped and counted).
  `compose` runs one thread per UI pixel and walks only its tile's commands, in order: SDF anti-aliasing, alpha over.
- **Text.** FreeType renders ASCII 32-126 at each size once into a 512-wide alpha atlas (60,928 B for 13/16/22 px);
  no shaping, Latin only.
- **Window.** SDL3 letterboxes both textures to the window and maps the mouse back to UI pixels. `Input.merge` folds
  frames polled between two UI frames, so no click is lost when the UI is drawn every few app iterations. With
  `scripted` set, real mouse events are ignored and only `push()`ed events count (checks that drive the window).

## Layer ownership

`Layer(font)` owns its device context, draw-list, bin, count, atlas and RGBA device buffers, a pinned host RGBA buffer,
and the compiled `compose` function. Construction uploads the atlas and synchronizes while the font is borrowed.
After `Ui.finish()`, `layer.render(ui)` uploads the fixed host tables, launches the same compose kernel, copies RGBA
into `layer.pixels`, and synchronizes while `ui` is borrowed. Owners remain in the struct throughout GPU work.
`pixels` is reused each frame and can be passed to `Window.present` as `Int(layer.pixels.unsafe_ptr())`.

Use the same font for the layer and UI. Dimensions remain build-time `UI_W` / `UI_H`, positive multiples of 16;
atlases larger than `AW * AH` are rejected at construction. `launch()` enqueues compose using the last uploaded
commands; callers using it directly must synchronize before reading results. No new kernel or frame allocations.

## Budgets

| buffer | bytes |
|---|---|
| draw list 4096 x 8 x u32 | 128 KB |
| tile bins 80 x 45 x 64 x u16 | 460 KB |
| tile counts 80 x 45 x u32 | 14 KB |
| atlas 512 x 256 x u8 (device) | 128 KB |
| layer 1280 x 720 x u32 (device) | 3.7 MB |
| Layer pinned host RGBA 1280 x 720 x u32 | 3.7 MB |

All allocated once. Per frame: one copy of list + bins + counts, one compose launch, one layer copy back, one texture
upload.

## Not yet

Docking (drag, resize, snap, collapse, saved layout), plots with axes, slider and text input, menus, DPI scaling.
