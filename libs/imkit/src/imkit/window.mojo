"""SDL3 window for the engine's frames (docs/RENDERER.md, GUI): one resizable window, one streaming RGBA texture at the
render size W x H, letterboxed by SDL (mouse coordinates come back in W x H pixels), vsync. SDL3 is the system library,
reached through OwnedDLHandle (no binding, no build flag). Event layouts: SDL 3.4 (offsets checked with offsetof).

    var win = Window("Kinestride", W, H)
    var inp = win.poll()            # every frame: mouse, wheel, buttons, keys, quit
    win.present(Int(out_h.unsafe_ptr()))   # a W x H RGBA frame in host memory
"""
from std.ffi import OwnedDLHandle, external_call

comptime EV_QUIT = 0x100
comptime EV_CLOSE = 0x210
comptime EV_KEY_DOWN = 0x300
comptime EV_KEY_UP = 0x301
comptime EV_MOTION = 0x400
comptime EV_BUTTON_DOWN = 0x401
comptime EV_BUTTON_UP = 0x402
comptime EV_WHEEL = 0x403


@fieldwise_init
struct Input(Copyable, Movable):
    """One frame's input, in render pixels. Mouse buttons are bits (left 1, middle 2, right 4); keys are SDL scancodes
    below 128 as bits of two words (pressed: went down this frame)."""
    var x: Float32
    var y: Float32
    var dx: Float32
    var dy: Float32
    var wheel: Float32
    var down: UInt32
    var pressed: UInt32
    var released: UInt32
    var keys: SIMD[DType.uint64, 2]
    var quit: Bool

    def key(self, scancode: Int) -> Bool:
        return (self.keys[scancode >> 6] >> UInt64(scancode & 63)) & 1 == 1


def readable(fd: Int, ms: Int) -> Bool:
    """poll(2) one fd for input for up to ms milliseconds."""
    var pfd = SIMD[DType.int32, 2](Int32(fd), 1)  # struct pollfd: fd, events POLLIN (revents in the high half)
    return external_call["poll", Int32](UnsafePointer(to=pfd), UInt64(1), Int32(ms)) > 0


struct Window(Movable):
    var sdl: OwnedDLHandle
    var win: Int
    var ren: Int
    var tex: Int
    var w: Int
    var h: Int
    var ev: List[UInt8]
    var x: Float32
    var y: Float32
    var down: UInt32

    def __init__(out self, title: String, w: Int, h: Int) raises:
        self.sdl = OwnedDLHandle("libSDL3.so.0")
        self.w, self.h, self.x, self.y, self.down = w, h, 0, 0, 0
        self.ev = List[UInt8](length=128, fill=0)
        if not self.sdl.get_function[Bool]("SDL_Init")(UInt32(0x20)):  # SDL_INIT_VIDEO
            raise Error("SDL_Init failed")
        var scale = max(1, 1280 // w)  # a small render size opens at least 1280 wide; SDL scales it
        var t = title.copy()
        self.win = self.sdl.get_function[Int]("SDL_CreateWindow")(t.as_c_string_slice().unsafe_ptr(), Int32(w * scale), Int32(h * scale), UInt64(0x20 | 0x2000))
        self.ren = self.sdl.get_function[Int]("SDL_CreateRenderer")(self.win, Int(0))
        if self.win == 0 or self.ren == 0:
            raise Error("SDL window or renderer failed")
        _ = self.sdl.get_function[Bool]("SDL_SetRenderVSync")(self.ren, Int32(1))
        _ = self.sdl.get_function[Bool]("SDL_SetRenderLogicalPresentation")(self.ren, Int32(w), Int32(h), Int32(2))  # letterbox
        self.tex = self.sdl.get_function[Int]("SDL_CreateTexture")(self.ren, UInt32(0x16762004), Int32(1), Int32(w), Int32(h))  # RGBA32, streaming
        if self.tex == 0:
            raise Error("SDL texture failed")

    def poll(mut self) raises -> Input:
        var inp = Input(self.x, self.y, 0, 0, 0, self.down, 0, 0, SIMD[DType.uint64, 2](0), False)
        var e = self.ev.unsafe_ptr()
        while self.sdl.get_function[Bool]("SDL_PollEvent")(e):
            _ = self.sdl.get_function[Bool]("SDL_ConvertEventToRenderCoordinates")(self.ren, e)
            var kind = Int(e.unsafe_bitcast[UInt32]()[0])
            var f = e.unsafe_bitcast[Float32]()
            if kind == EV_QUIT or kind == EV_CLOSE:
                inp.quit = True
            elif kind == EV_MOTION:
                inp.x, inp.y = f[7], f[8]
                inp.dx += f[9]
                inp.dy += f[10]
            elif kind == EV_BUTTON_DOWN or kind == EV_BUTTON_UP:
                var bit = UInt32(1) << UInt32(Int(e[24]) - 1)
                inp.x, inp.y = f[7], f[8]
                if kind == EV_BUTTON_DOWN:
                    inp.down |= bit
                    inp.pressed |= bit
                else:
                    inp.down &= ~bit
                    inp.released |= bit
            elif kind == EV_WHEEL:
                inp.wheel += f[7]
            elif kind == EV_KEY_DOWN and e[37] == 0:  # not a repeat
                var sc = Int(e.unsafe_bitcast[UInt32]()[6])
                if sc < 128:
                    inp.keys[sc >> 6] |= UInt64(1) << UInt64(sc & 63)
        self.x, self.y, self.down = inp.x, inp.y, inp.down
        return inp^

    def present(mut self, pixels: Int) raises:
        """Show a W x H RGBA frame (host memory, row-major, 4 bytes per pixel)."""
        _ = self.sdl.get_function[Bool]("SDL_UpdateTexture")(self.tex, Int(0), pixels, Int32(self.w * 4))
        _ = self.sdl.get_function[Bool]("SDL_RenderClear")(self.ren)
        _ = self.sdl.get_function[Bool]("SDL_RenderTexture")(self.ren, self.tex, Int(0), Int(0))
        _ = self.sdl.get_function[Bool]("SDL_RenderPresent")(self.ren)

    def push(mut self, kind: Int, a: Int = 0, x: Float32 = 0, y: Float32 = 0, rx: Float32 = 0, ry: Float32 = 0) raises:
        """Queue a synthetic event (tests, scripted checks): motion (x, y, rx, ry), button a down/up at (x, y), wheel
        (x = amount), key a (scancode) down."""
        for k in range(128):
            self.ev[k] = 0
        var e = self.ev.unsafe_ptr()
        e.unsafe_bitcast[UInt32]()[0] = UInt32(kind)
        var f = e.unsafe_bitcast[Float32]()
        if kind == EV_MOTION or kind == EV_BUTTON_DOWN or kind == EV_BUTTON_UP:
            e[24] = UInt8(a)
            e[25] = UInt8(1 if kind == EV_BUTTON_DOWN else 0)
            f[7], f[8], f[9], f[10] = x, y, rx, ry
        elif kind == EV_WHEEL:
            f[7] = x
        elif kind == EV_KEY_DOWN:
            e.unsafe_bitcast[UInt32]()[6] = UInt32(a)
            e[36] = 1
        _ = self.sdl.get_function[Bool]("SDL_PushEvent")(e)

    def close(mut self) raises:
        self.sdl.get_function[NoneType]("SDL_DestroyTexture")(self.tex)
        self.sdl.get_function[NoneType]("SDL_DestroyRenderer")(self.ren)
        self.sdl.get_function[NoneType]("SDL_DestroyWindow")(self.win)
        self.sdl.get_function[NoneType]("SDL_Quit")()
