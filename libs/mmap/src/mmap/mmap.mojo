"""Memory-mapped files: the whole file as a zero-copy Span, read-only or shared-writable."""
from std.ffi import external_call

comptime NORMAL = 0
comptime RANDOM = 1
comptime SEQUENTIAL = 2
comptime WILLNEED = 3
comptime DONTNEED = 4
comptime _CLOEXEC = 0o2000000
comptime _MAP_FAILED = -1


def _open(path: String, flags: Int) raises -> Int32:
    var p = path.copy()
    var fd = external_call["open64", Int32](p.as_c_string_span().ptr(), Int32(flags | _CLOEXEC), Int32(0o644))
    if fd < 0:
        raise Error("mmap: cannot open ", path)
    return fd


struct MappedFile(Movable, Sized):
    """A mapped file. `bytes()` / `mut_bytes()` view the mapping; it is unmapped when the value dies."""

    var base: Int
    var size: Int
    var writable: Bool

    def __init__(out self, path: String, write: Bool = False) raises:
        var fd = _open(path, 2 if write else 0)
        self = Self(fd, path, write)

    def __init__(out self, fd: Int32, path: String, write: Bool) raises:
        self.writable = write
        self.base = 0
        self.size = Int(external_call["lseek64", Int64](fd, Int64(0), Int32(2)))
        if self.size <= 0:
            _ = external_call["close", Int32](fd)
            raise Error("mmap: cannot map an empty file: ", path)
        var prot = 3 if write else 1
        self.base = external_call["mmap", Int](Int(0), self.size, Int32(prot), Int32(1), fd, Int64(0))
        _ = external_call["close", Int32](fd)
        if self.base == _MAP_FAILED:
            self.base = 0
            raise Error("mmap: mmap failed: ", path)

    def __len__(self) -> Int:
        return self.size

    def bytes(self) -> Span[UInt8, origin_of(self)]:
        """The whole file, no copy."""
        return Span(unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=self.base), length=self.size)

    def mut_bytes(mut self) raises -> Span[UInt8, origin_of(self)]:
        """The whole file, writable; changes reach the file (flush() makes them durable)."""
        if not self.writable:
            raise Error("mmap: mapping is read-only")
        return Span(unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=self.base), length=self.size)

    def advise(self, advice: Int) raises:
        """madvise over the whole mapping: NORMAL, RANDOM, SEQUENTIAL, WILLNEED or DONTNEED."""
        if external_call["madvise", Int32](self.base, self.size, Int32(advice)) != 0:
            raise Error("mmap: madvise failed")

    def flush(self) raises:
        """msync(MS_SYNC): block until written changes are on disk."""
        if external_call["msync", Int32](self.base, self.size, Int32(4)) != 0:
            raise Error("mmap: msync failed")

    def __deinit__(deinit self):
        if self.base:
            _ = external_call["munmap", Int32](self.base, self.size)


def create(path: String, size: Int) raises -> MappedFile:
    """Create (or truncate) `path` with `size` zero bytes and map it writable."""
    var fd = _open(path, 2 | 0o100 | 0o1000)
    if external_call["ftruncate64", Int32](fd, Int64(size)) != 0:
        _ = external_call["close", Int32](fd)
        raise Error("mmap: cannot size ", path)
    return MappedFile(fd, path, True)
