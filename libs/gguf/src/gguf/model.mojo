"""GGUF v3 little-endian reader and writer.

The model keeps the header prefix (magic .. tensor infos) in one flat buffer; KV values are typed
spans into it, validated by a full walk (all 13 value types, nested arrays). Tensor data is never
loaded: `rewrite` streams it from the source file in CHUNK-sized pread/write pieces.
"""
from std.ffi import external_call, c_ssize_t

comptime MAGIC = 0x46554747
comptime CHUNK = 4 << 20
comptime T_STRING = 8
comptime T_ARRAY = 9
comptime O_WRONLY_CREAT_TRUNC = 1 | 0o100 | 0o1000

def fixed_size(t: Int) -> Int:
    """Byte size of a fixed-width value type; 0 for string, array and unknown."""
    if t == 0 or t == 1 or t == 7:
        return 1
    if t == 2 or t == 3:
        return 2
    if t == 4 or t == 5 or t == 6:
        return 4
    if t == 10 or t == 11 or t == 12:
        return 8
    return 0

def pad_to(n: Int, align: Int) -> Int:
    return (n + align - 1) // align * align

def open_fd(path: String, flags: Int) raises -> Int32:
    var p = path.copy()
    var fd = external_call["open64", Int32](p.as_c_string_span().ptr(), Int32(flags), Int32(0o644))
    if fd < 0:
        raise Error("cannot open " + path)
    return fd

def pread_into(fd: Int32, mut dst: List[UInt8], at: Int, n: Int, off: Int) raises:
    var got = 0
    while got < n:
        var r = external_call["pread", c_ssize_t](fd, dst.unsafe_ptr().unsafe_offset(at + got), n - got, Int64(off + got))
        if r <= 0:
            raise Error("short read at byte " + String(off + got))
        got += Int(r)

def pwrite_all(fd: Int32, src: List[UInt8], at: Int, n: Int, off: Int) raises:
    var done = 0
    while done < n:
        var r = external_call["pwrite", c_ssize_t](fd, src.unsafe_ptr().unsafe_offset(at + done), n - done, Int64(off + done))
        if r <= 0:
            raise Error("write failed")
        done += Int(r)

def put(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))

def put_str(mut out: List[UInt8], s: String):
    put(out, s.byte_length(), 8)
    out.extend(s.as_bytes())

@fieldwise_init
struct KV(Copyable, Movable):
    var key: String
    var vtype: Int
    var start: Int  # value payload span in Gguf.buf
    var end: Int

@fieldwise_init
struct TensorInfo(Copyable, Movable):
    var name: String
    var dims: List[Int]
    var ttype: Int
    var offset: Int  # relative to the data section

struct Gguf(Movable):
    var fd: Int32
    var fsize: Int
    var buf: List[UInt8]
    var pos: Int
    var version: Int
    var kvs: List[KV]
    var tensors: List[TensorInfo]
    var alignment: Int
    var data_offset: Int

    def __init__(out self, path: String) raises:
        self.fd = open_fd(path, 0)
        self.fsize = Int(external_call["lseek", Int](self.fd, Int64(0), Int32(2)))
        self.buf = List[UInt8]()
        self.pos = 0
        self.version = 0
        self.kvs = List[KV]()
        self.tensors = List[TensorInfo]()
        self.alignment = 32
        self.data_offset = 0
        if self._u32() != MAGIC:
            raise Error(path + " is not a GGUF file")
        self.version = self._u32()
        if self.version != 3:
            raise Error("only GGUF v3 is supported, got v" + String(self.version))
        var n_tensors = self._u64()
        var n_kv = self._u64()
        for _ in range(n_kv):
            var key = self._str()
            var vtype = self._u32()
            var start = self.pos
            self._skip_value(vtype)
            self.kvs.append(KV(key^, vtype, start, self.pos))
        for k in range(len(self.kvs)):
            if self.kvs[k].key == "general.alignment":
                if self.kvs[k].vtype != 4:
                    raise Error("general.alignment is not uint32")
                self.pos = self.kvs[k].start
                self.alignment = self._u32()
        if self.alignment == 0 or (self.alignment & (self.alignment - 1)) != 0:
            raise Error("alignment " + String(self.alignment) + " is not a power of two")
        self.pos = self.kvs[len(self.kvs) - 1].end if len(self.kvs) > 0 else 24
        for _ in range(n_tensors):
            var name = self._str()
            var dims = List[Int]()
            for _ in range(self._u32()):
                dims.append(self._u64())
            var ttype = self._u32()
            self.tensors.append(TensorInfo(name^, dims^, ttype, self._u64()))
        self.data_offset = pad_to(self.pos, self.alignment)
        var prev = 0
        for t in range(len(self.tensors)):
            var off = self.tensors[t].offset
            if off < prev or self.data_offset + off > self.fsize:
                raise Error("tensor " + self.tensors[t].name + ": offset " + String(off) + " out of order or past EOF")
            prev = off

    def __deinit__(deinit self):
        _ = external_call["close", Int32](self.fd)

    def _need(mut self, n: Int) raises:
        if n < 0 or n > self.fsize:
            raise Error("truncated GGUF: bad length " + String(n))
        var end = self.pos + n
        if end <= len(self.buf):
            return
        if end > self.fsize:
            raise Error("truncated GGUF: need byte " + String(end) + " of " + String(self.fsize))
        var have = len(self.buf)
        var want = min(self.fsize, max(end, max(2 * have, 1 << 20)))
        self.buf.resize(want, 0)
        pread_into(self.fd, self.buf, have, want - have, have)

    def _int(mut self, width: Int) raises -> Int:
        self._need(width)
        var v = 0
        for k in range(width):
            v |= Int(self.buf[self.pos + k]) << (8 * k)
        self.pos += width
        return v

    def _u32(mut self) raises -> Int:
        return self._int(4)

    def _u64(mut self) raises -> Int:
        return self._int(8)

    def _str(mut self) raises -> String:
        var n = self._u64()
        self._need(n)
        var s = String(unsafe_from_utf8=Span(self.buf)[self.pos : self.pos + n])
        self.pos += n
        return s^

    def _skip_value(mut self, vtype: Int) raises:
        var w = fixed_size(vtype)
        if w > 0:
            self._need(w)
            self.pos += w
        elif vtype == T_STRING:
            var n = self._u64()
            self._need(n)
            self.pos += n
        elif vtype == T_ARRAY:
            var et = self._u32()
            var n = self._u64()
            if et > 12:
                raise Error("unknown array element type " + String(et))
            var ew = fixed_size(et)
            if ew > 0:
                if n > self.fsize // ew:
                    raise Error("truncated GGUF: array of " + String(n))
                self._need(n * ew)
                self.pos += n * ew
            else:
                for _ in range(n):
                    self._skip_value(et)
        else:
            raise Error("unknown value type " + String(vtype))

    def find(self, key: String) -> Int:
        for k in range(len(self.kvs)):
            if self.kvs[k].key == key:
                return k
        return -1

    def summary(self) -> String:
        return String("kv ", len(self.kvs), " tensors ", len(self.tensors), " alignment ", self.alignment,
                      " data_offset ", self.data_offset)

    def rewrite(mut self, out_path: String, name: String, remove: List[String]) raises:
        """Write the model to out_path. With no edit the layout is the source's; with an edit it is
        what gguf_new_metadata.py (GGUFWriter) produces: architecture KV first, `general.name`
        replaced in place or appended, removed keys dropped, no padding after an empty tensor list."""
        var edited = name.byte_length() > 0 or len(remove) > 0
        var arch = self.find("general.architecture")
        if edited and arch < 0:
            raise Error("cannot edit: no general.architecture KV")
        var order = List[Int]()
        if edited:
            order.append(arch)
        for i in range(len(self.kvs)):
            if edited and (i == arch or self.kvs[i].key in remove):
                continue
            order.append(i)
        var name_at = len(self.buf)
        put_str(self.buf, name)
        var hdr = List[UInt8]()
        put(hdr, MAGIC, 4)
        put(hdr, 3, 4)
        put(hdr, len(self.tensors), 8)
        var n_kv_at = len(hdr)
        put(hdr, 0, 8)
        var n_kv = 0
        var named = name.byte_length() == 0
        for i in order:
            var kv = self.kvs[i].copy()
            if name.byte_length() > 0 and kv.key == "general.name":
                kv = KV(kv.key.copy(), T_STRING, name_at, len(self.buf))
                named = True
            put_str(hdr, kv.key)
            put(hdr, kv.vtype, 4)
            hdr.extend(Span(self.buf)[kv.start : kv.end])
            n_kv += 1
        if not named:
            put_str(hdr, "general.name")
            put(hdr, T_STRING, 4)
            hdr.extend(Span(self.buf)[name_at:])
            n_kv += 1
        for k in range(8):
            hdr[n_kv_at + k] = UInt8((n_kv >> (8 * k)) & 0xFF)
        var total = self.fsize - self.data_offset
        var out_off = 0
        var spans = List[Int]()
        for t in range(len(self.tensors)):
            var nxt = self.tensors[t + 1].offset if t + 1 < len(self.tensors) else total
            var info = self.tensors[t].copy()
            spans.append(nxt - info.offset)
            put_str(hdr, info.name)
            put(hdr, len(info.dims), 4)
            for d in info.dims:
                put(hdr, d, 8)
            put(hdr, info.ttype, 4)
            put(hdr, out_off, 8)
            out_off += pad_to(nxt - info.offset, self.alignment)
        var fout = open_fd(out_path, O_WRONLY_CREAT_TRUNC)
        pwrite_all(fout, hdr, 0, len(hdr), 0)
        var opos = len(hdr)
        var zeros = List[UInt8](length=self.alignment, fill=0)
        if len(self.tensors) > 0 or not edited:
            var pad = pad_to(opos, self.alignment) - opos
            pwrite_all(fout, zeros, 0, pad, opos)
            opos += pad
        var chunk = List[UInt8](length=CHUNK, fill=0)
        for t in range(len(self.tensors)):
            var left = spans[t]
            var at = self.data_offset + self.tensors[t].offset
            while left > 0:
                var n = min(left, CHUNK)
                pread_into(self.fd, chunk, 0, n, at)
                pwrite_all(fout, chunk, 0, n, opos)
                opos += n
                at += n
                left -= n
            var pad = pad_to(spans[t], self.alignment) - spans[t]
            pwrite_all(fout, zeros, 0, pad, opos)
            opos += pad
        if external_call["close", Int32](fout) != 0:
            raise Error("close failed on " + out_path)
