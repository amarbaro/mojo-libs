"""GPU side of a Ui (docs/design.md, Layer): device buffers, the compose launch and the pinned RGBA the window presents,
all allocated once on the app's own DeviceContext. render_into(ui, buf) after ui.finish() uploads only what the frame used
(n commands, its tile entries, the tile offsets, styles) and composes into a device buffer; render(ui) is that into the layer's
own buffer plus the 3.7 MB copy to `pixels` (readback()), which only a host consumer such as SDL's texture upload needs.

    var layer = Layer(ctx, ui)                 # once: buffers, the font atlas from ui
    layer.render(ui)                           # every frame, after ui.finish()
    win.present(frame, Int(layer.pixels.unsafe_ptr()))
"""
from max.gpu.host import DeviceBuffer, DeviceContext, HostBuffer
from layout import TileTensor, row_major
from .font import AW
from .draw import AH, CW, ISRC, NBIN, NCMD, NSTY, TX, TY, UH, UW, compose
from .ui import Ui


def image_fits(n: Int, w: Int, h: Int) -> Bool:
    """Can a w x h picture held in n pixels go to the ISRC pool (Ui.image takes sides up to 0xFFFF)?"""
    return 0 < w <= 0xFFFF and 0 < h <= 0xFFFF and w * h <= ISRC and n >= w * h


struct Layer(Movable):
    var ctx: DeviceContext[]
    var img: DeviceBuffer[DType.uint32]
    var cmd: DeviceBuffer[DType.uint32]
    var bins: DeviceBuffer[DType.uint16]
    var off: DeviceBuffer[DType.uint32]
    var atlas: DeviceBuffer[DType.uint8]
    var sty: DeviceBuffer[DType.uint32]
    var src: DeviceBuffer[DType.uint32]  # image sources (Ui.image): the app writes its RGBA here
    var pixels: HostBuffer[DType.uint32]  # the composed layer, valid after render() returns

    def __init__(out self, ctx: DeviceContext[], ui: Ui) raises:
        comptime assert UW > 0 and UH > 0 and UW % 16 == 0 and UH % 16 == 0, "UI_W, UI_H: positive multiples of 16"
        if len(ui.d.font.atlas) > AW * AH:
            raise Error("Layer: font atlas " + String(len(ui.d.font.atlas)) + " B over the compose capacity " + String(AW * AH))
        self.ctx = ctx
        self.img = ctx.enqueue_create_buffer[DType.uint32](UW * UH)
        self.cmd = ctx.enqueue_create_buffer[DType.uint32](NCMD * CW)
        self.bins = ctx.enqueue_create_buffer[DType.uint16](NBIN)
        self.off = ctx.enqueue_create_buffer[DType.uint32](TX * TY + 1)
        self.atlas = ctx.enqueue_create_buffer[DType.uint8](AW * AH)
        self.sty = ctx.enqueue_create_buffer[DType.uint32](NSTY * 8)
        self.src = ctx.enqueue_create_buffer[DType.uint32](ISRC)
        self.pixels = ctx.enqueue_create_host_buffer[DType.uint32](UW * UH)
        self.src.enqueue_fill(0)
        ctx.enqueue_copy(self.atlas.create_sub_buffer[DType.uint8](0, len(ui.d.font.atlas)), ui.d.font.atlas.unsafe_ptr())
        ctx.synchronize()  # the atlas is the caller's

    def set_image(mut self, px: Span[UInt32, _], w: Int, h: Int) raises:
        """Copy a w x h picture (packed r | g << 8 | b << 16 | a << 24, row-major) to pool offset 0 and wait; draw it with
        Ui.image(.., 0, w, h). ISRC is the pool size in pixels, set by -DUI_IMG=; a picture over it raises, the pool is untouched."""
        if not image_fits(len(px), w, h):
            raise Error("Layer.set_image: " + String(w) + " x " + String(h) + " (" + String(len(px)) + " px given) does not fit ISRC " + String(ISRC))
        self.ctx.enqueue_copy(self.src.create_sub_buffer[DType.uint32](0, w * h), px.unsafe_ptr())
        self.ctx.synchronize()  # px is the caller's

    def launch(self) raises:
        """Compose what was last uploaded into the layer's own buffer (enqueue only)."""
        self.launch_to(self.img)

    def launch_to(self, buf: DeviceBuffer[DType.uint32]) raises:
        """Compose what was last uploaded into `buf` (UW * UH u32, enqueue only)."""
        self.ctx.enqueue_function(self.ctx.compile_function[compose](), TileTensor(buf, row_major[UW * UH]()),
            TileTensor(self.cmd, row_major[NCMD * CW]()), TileTensor(self.bins, row_major[NBIN]()),
            TileTensor(self.off, row_major[TX * TY + 1]()), TileTensor(self.atlas, row_major[AW * AH]()),
            TileTensor(self.src, row_major[ISRC]()), TileTensor(self.sty, row_major[NSTY * 8]()), grid_dim=(UW * UH + 255) // 256, block_dim=256)

    def render_into(self, ui: Ui, buf: DeviceBuffer[DType.uint32]) raises:
        """Upload the finished frame and compose into the caller's device buffer: no layer readback, so a GPU consumer
        (a texture, a blend kernel on the same DeviceContext) reads it in stream order. Returns when ui's lists are free to reuse."""
        if ui.d.binned != ui.d.n:
            raise Error("Layer.render: call Ui.finish() first")
        if len(buf) != UW * UH:
            raise Error("Layer.render_into: buf holds " + String(len(buf)) + " u32, the layer is " + String(UW * UH))
        if ui.d.n:
            self.ctx.enqueue_copy(self.cmd.create_sub_buffer[DType.uint32](0, ui.d.n * CW), ui.d.cmd.unsafe_ptr())
        var used = Int(ui.d.off[TX * TY])
        if used:
            self.ctx.enqueue_copy(self.bins.create_sub_buffer[DType.uint16](0, used), ui.d.bins.unsafe_ptr())
        self.ctx.enqueue_copy(self.off, ui.d.off.unsafe_ptr())
        if ui.d.ns > 1:
            self.ctx.enqueue_copy(self.sty.create_sub_buffer[DType.uint32](0, ui.d.ns * 8), ui.d.sty.unsafe_ptr())
        self.launch_to(buf)
        self.ctx.synchronize()  # ui's lists are read by the copies above

    def readback(self) raises:
        """Copy the layer's own buffer to `pixels` and wait (after render_into(ui, layer.img))."""
        self.ctx.enqueue_copy(self.pixels, self.img)
        self.ctx.synchronize()

    def render(self, ui: Ui) raises:
        """Upload the finished frame, compose, copy to pixels; returns when pixels is ready (render_into + readback)."""
        self.render_into(ui, self.img)
        self.readback()
