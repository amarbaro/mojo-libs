# mojo-imkit

An immediate-mode GUI for Mojo apps, drawn by the GPU. It takes the idea behind Dear ImGui and imgui-bundle (widgets
are function calls made every frame, no retained widget tree) and builds it in Mojo around a GPU app's own frame:
widgets append to one flat draw list, one `compose` kernel turns that list into an RGBA layer, and the window blends
the layer over the app's picture. No Python UI process, no C++ library, no bundled windowing: the system's SDL3 and
FreeType are called through Mojo's FFI.

First user: [Kinestride](../kinestride)'s engine GUI (run controls, per-fly cards, telemetry over the live scene).

## Modules

| module | what it does |
|---|---|
| `imkit.window` | SDL3 window, vsync, letterboxed streaming texture; `poll() -> Input` (mouse, wheel, buttons, keys, quit), `present(frame, ui)`, `push()` synthetic events for scripted checks |
| `imkit.layer` | `Layer(ctx, ui)`: the GPU side on your DeviceContext (buffers, atlas from `ui`, image sources `src`); `render(ui)` after `Ui.finish()` uploads only what the frame used and fills the pinned `pixels` |
| `imkit.font` | glyph atlas from a TrueType font (ASCII 32-126, a few pixel sizes, alpha8), built once at start |
| `imkit.ui` | `Ui`: `begin(input)`, `panel`, `button`, `icon`, `bar`, `spark`, `text`, `rect`, `line`, `tri`, `image`, `finish()`; the `compose` kernel; a dark theme |

## Use

```mojo
from imkit.window import Window
from imkit.font import Font
from imkit.layer import Layer
from imkit import ui as im
from max.gpu.host import DeviceContext

var win = Window("App", W, H, im.UW, im.UH)          # W x H: your frame; UW x UH: the UI layer
var u = im.Ui(Font("/usr/share/fonts/TTF/Roboto-Medium.ttf", [13, 16, 22]))
var layer = Layer(DeviceContext(), u)                # once, on your app's context: buffers, the atlas from u
while True:
    var inp = win.poll()
    if inp.quit:
        break
    u.begin(inp)
    u.panel(20, 16, 400, 92, "Run")
    if u.icon(1, 1):                                  # 0 play, 1 pause, 2 step, 3 stop
        pause()
    u.finish()                                        # bins the commands into 16 x 16 tiles
    layer.render(u)                                   # uploads what the frame used, composes, copies back; synchronizes
    win.present(frame_ptr, Int(layer.pixels.unsafe_ptr()))
```

A complete app: Kinestride's live viewer (`fly-connectome/agent/body_engine/live.mojo`, `-DGUI=1`).

## Check

```
tools/gate.sh      # precompile, font_test, ui_test (GPU, under gpu-wait), window_test (opens a window ~2 s)
```

Numbers (RX 7900 XTX, 1280 x 720, 150 commands): compose 17.7 us per launch; draw list 128 KB, tile bins 460 KB,
atlas 61 KB for three sizes, all allocated once. Design and limits: [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

Mojo 1.1 and MAX 26.6 (`max.gpu`, `layout`), a GPU MAX supports, system `libSDL3.so.0` (3.4) and
`libfreetype.so.6` (2.14). Struct offsets are checked against those versions' headers.
