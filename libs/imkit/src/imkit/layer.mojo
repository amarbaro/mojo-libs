"""Reusable compose buffers, compiled kernel and host RGBA output, allocated once at startup."""
from max.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from layout import TileTensor, row_major
from .font import AW, Font
from .ui import AH, CW, ISRC, NCMD, TCAP, TX, TY, UH, UW, Ui, compose


comptime ComposeKernel = type_of(DeviceContext().compile_function[compose]())


# The type parameter keeps the SDK's AnyOrigin argument types out of a concrete
# field declaration on Mojo 1.1. It is fixed to compose by the assertion below.
struct Layer[Kernel: ImplicitlyCopyable & Movable & Deinitable = ComposeKernel](Movable):
    var ctx: DeviceContext
    var img: DeviceBuffer[DType.uint32]
    var cmd: DeviceBuffer[DType.uint32]
    var bins: DeviceBuffer[DType.uint16]
    var counts: DeviceBuffer[DType.uint32]
    var atlas: DeviceBuffer[DType.uint8]
    var src: DeviceBuffer[DType.uint32]  # image source pixels (Ui.image): the app copies its RGBA here
    var pixels: HostBuffer[DType.uint32]
    var kernel: Self.Kernel

    def __init__(out self, font: Font) raises:
        comptime assert UW > 0 and UH > 0 and UW % 16 == 0 and UH % 16 == 0, "UI dimensions must be positive multiples of 16"
        if len(font.atlas) > AW * AH:
            raise Error("Font atlas exceeds the compose capacity")
        self.ctx = DeviceContext()
        self.img = self.ctx.enqueue_create_buffer[DType.uint32](UW * UH)
        self.cmd = self.ctx.enqueue_create_buffer[DType.uint32](NCMD * CW)
        self.bins = self.ctx.enqueue_create_buffer[DType.uint16](TX * TY * TCAP)
        self.counts = self.ctx.enqueue_create_buffer[DType.uint32](TX * TY)
        self.atlas = self.ctx.enqueue_create_buffer[DType.uint8](AW * AH)
        self.src = self.ctx.enqueue_create_buffer[DType.uint32](ISRC)
        self.src.enqueue_fill(0)
        self.pixels = self.ctx.enqueue_create_host_buffer[DType.uint32](UW * UH)
        comptime assert Self.Kernel == ComposeKernel, "Layer kernel must be compose"
        self.kernel = rebind[Self.Kernel](self.ctx.compile_function[compose]())
        self.ctx.enqueue_copy(self.atlas.create_sub_buffer[DType.uint8](0, len(font.atlas)), font.atlas.unsafe_ptr())
        self.ctx.synchronize()

    def launch(self) raises:
        """Compose uploaded commands; enqueue only, useful for measuring the kernel."""
        self.ctx.enqueue_function(rebind[ComposeKernel](self.kernel),
            TileTensor(self.img, row_major[UW * UH]()),
            TileTensor(self.cmd, row_major[NCMD * CW]()),
            TileTensor(self.bins, row_major[TX * TY * TCAP]()),
            TileTensor(self.counts, row_major[TX * TY]()),
            TileTensor(self.atlas, row_major[AW * AH]()),
            TileTensor(self.src, row_major[ISRC]()),
            grid_dim=(UW * UH + 255) // 256, block_dim=256)

    def render(mut self, ui: Ui) raises:
        """Render after Ui.finish; pixels is ready on return, reused until the next render.

        Use the same font used to construct this Layer. No buffers are allocated here.
        """
        self.ctx.enqueue_copy(self.cmd, ui.cmd.unsafe_ptr())
        self.ctx.enqueue_copy(self.bins, ui.bins.unsafe_ptr())
        self.ctx.enqueue_copy(self.counts, ui.cnt.unsafe_ptr())
        self.launch()
        self.ctx.enqueue_copy(self.pixels, self.img)
        self.ctx.synchronize()
