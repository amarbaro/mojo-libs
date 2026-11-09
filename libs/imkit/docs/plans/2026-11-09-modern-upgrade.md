# imkit modern upgrade

About 770 added lines make imkit a themeable, GPU-native UI with three looks, Unicode text and real widgets, and the
frame gets faster, not slower: the 3.7 MB per-frame readback goes away. Inputs: Codex review
(`.work/briefs/codex-suggestions.md`), DeepSeek review and code (`.work/briefs/deepseek-*.md`). Mario's choices:
three presets (glass, neon, flat) from one theme; UTF-8 + dynamic atlas; SDF effects; animation + DPI; new widgets;
offline Blender/ComfyUI asset atlas; lane A = render, lane B = widgets.

## Principles
- Keep the 8 x u32 command and host tile binning (already 16 x 16, prefix sum). No GPU binning until a profile says so.
- Effects that are functions of distance (border, shadow, glow, gradient) live in the one compose pass.
- Backdrop blur is the only extra pass: separable blur of the scene at 1/4 resolution, sampled by compose.
- Rare parameters go in a per-frame `Style` table (u16 id in the kind word), not wider commands.
- Every new command kind has a CPU reference in `tests/ui_cpu_test.mojo` and a mutant in `scripts/mutants.sh`.
- Public widget calls stay source-compatible (`panel(x0,y0,x1,y1,title)`, `button(id,label,w,...)`).

## Steps (LOC = added lines, excluding tests and docs)

| # | Step | Owner | LOC | Gate |
|---|------|-------|----:|------|
| 0 | Seam: split `ui.mojo` into `draw.mojo` (kinds, push, span, finish, compose) and `ui.mojo` (widgets); `theme.mojo` with `Theme` + `glass/neon/flat` built with `rgba()` | A (first commit; B rebases on it) | +30 | existing tests green |
| A1 | `over()` helper; RRECT kind: border (u8 px/4), glow (u8 px), gradient (i8) in kind word high bits, border rgba in aux (DeepSeek layout, fixed) | A | 45 | CPU ref + mutant |
| A2 | `Style` table (u16 id): linear/radial gradient, shadow offset + radius; `span` pads by effect radius | A | 50 | CPU ref, span test |
| A3 | Clip rects (u16 id) for scroll/menu/table | A | 25 | clipped pixel test |
| A4 | `render_into(DeviceBuffer)`: no 3.7 MB readback per frame; host readback explicit | A | 30 | ms before/after |
| A5 | Backdrop blur: scene input + separable blur pass at 1/4 res, glass samples it | A | 60 | pixel test, ms |
| A6 | UTF-8 decode + codepoint cache + skyline atlas, FreeType rasterize on miss, dirty-rect upload | A | 130 | CJK + fallback test |
| A7 | Offline asset atlas: `tools/pack_atlas` reads PNGs (Blender icons, ComfyUI textures) -> bytes + manifest; `Ui.icon_img(name)` | A | 60 | round-trip test |
| B1 | Widgets read `self.theme` roles; preset switch at runtime | B | 30 | 3 golden frames |
| B2 | Animation: `begin(input, dt)`, id -> (cur, vel) spring table, evict untouched | B | 30 | step test |
| B3 | DPI: logical coords, scale in `push`, inverse on input, drawable-size query | B | 25 | 1.0 / 1.5 / 2.0 test |
| B4 | slider (drag capture), menu (one popup level), scroll list (virtualized, clip) | B | 110 | scripted input test |
| B5 | table (on scroll list), plot (decimate to 1 point per px, axes) | B | 80 | scripted input test |
| B6 | Demo `examples/gallery.mojo`: every widget, theme switcher, UTF-8 text | B | 80 | screenshot looked at |

## Order
Lane A lands step 0 first and tells the boss; lane B starts with B2 and B3 (window.mojo, new anim code) and rebases on step 0 before touching ui.mojo. A owns `draw.mojo`, `layer.mojo`,
`font.mojo`, new `atlas.mojo`; B owns `theme.mojo`, `ui.mojo` widgets, `window.mojo` input/DPI, examples.
B uses A's new kinds only through `Ui` methods A adds (`rrect`, `style`, `clip`); until they land B uses `rect`.

## Cuts
Retained widget tree, layout engine, docking, full text editor, Unicode shaping (HarfBuzz later via FFI), GPU binning,
per-widget kernels, runtime Blender/ComfyUI, MSDF (revisit after A6 if scaled text is soft).

## Assets
Blender (`blender-to-mojo`, `blender-conventions`) renders icons and 3D thumbnails; ComfyUI (`comfy-ops`) makes
panel textures and backgrounds. Both write PNGs to `assets/src/`; `tools/pack_atlas` packs them at build time.
