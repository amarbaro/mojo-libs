# Read an ONNX model (protobuf) into nodes, initializers and graph inputs/outputs. Pure Mojo, no
# protobuf library: only the ModelProto fields an inference graph uses are decoded.
from std.memory import bitcast
from mmap import MappedFile

comptime FLOAT = 1
comptime INT64 = 7


struct Tensor(Copyable, Movable):
    var name: String
    var dims: List[Int]
    var dtype: Int
    var f: List[Float32]  # FLOAT tensors
    var i: List[Int]  # INT64 and INT32 tensors

    def __init__(out self):
        self.name = String()
        self.dims = List[Int]()
        self.dtype = 0
        self.f = List[Float32]()
        self.i = List[Int]()

    def numel(self) -> Int:
        var n = 1
        for d in self.dims:
            n *= d
        return n


struct Attr(Copyable, Movable):
    var name: String
    var f: Float32
    var i: Int
    var s: String
    var ints: List[Int]
    var floats: List[Float32]
    var t: List[Tensor]  # zero or one

    def __init__(out self):
        self.name = String()
        self.f = 0.0
        self.i = 0
        self.s = String()
        self.ints = List[Int]()
        self.floats = List[Float32]()
        self.t = List[Tensor]()


struct Node(Copyable, Movable):
    var op: String
    var name: String
    var inputs: List[String]
    var outputs: List[String]
    var attrs: List[Attr]

    def __init__(out self):
        self.op = String()
        self.name = String()
        self.inputs = List[String]()
        self.outputs = List[String]()
        self.attrs = List[Attr]()

    def attr(self, name: StringSlice) -> Int:
        """Index into attrs, -1 when absent."""
        for k in range(len(self.attrs)):
            if self.attrs[k].name == name:
                return k
        return -1

    def int_attr(self, name: StringSlice, default: Int) -> Int:
        var k = self.attr(name)
        return self.attrs[k].i if k >= 0 else default

    def ints_attr(self, name: StringSlice) -> List[Int]:
        var k = self.attr(name)
        return self.attrs[k].ints.copy() if k >= 0 else List[Int]()


struct Model(Movable):
    var nodes: List[Node]
    var inits: List[Tensor]
    var inputs: List[String]  # graph inputs that are not initializers
    var outputs: List[String]

    def __init__(out self, path: String) raises:
        self.nodes = List[Node]()
        self.inits = List[Tensor]()
        self.inputs = List[String]()
        self.outputs = List[String]()
        var mf = MappedFile(path)  # read through the page cache; the weights are copied once, into inits
        var r = Reader(mf.bytes(), 0, len(mf))
        while r.more():
            var key = r.varint()
            if key == (7 << 3 | 2):
                var g = r.sub()
                self._graph(g)
            else:
                r.skip(key & 7)
        var names = List[String]()
        for t in self.inits:
            names.append(t.name)
        var keep = List[String]()
        for n in self.inputs:
            if n not in names:
                keep.append(n)
        self.inputs = keep^

    def init(self, name: StringSlice) -> Int:
        """Index into inits, -1 when absent."""
        for k in range(len(self.inits)):
            if self.inits[k].name == name:
                return k
        return -1

    def _graph(mut self, mut r: Reader) raises:
        while r.more():
            var key = r.varint()
            var f = key >> 3
            if f == 1 and key & 7 == 2:
                var s = r.sub()
                self.nodes.append(_node(s))
            elif f == 5 and key & 7 == 2:
                var s = r.sub()
                self.inits.append(_tensor(s))
            elif (f == 11 or f == 12) and key & 7 == 2:
                var s = r.sub()
                var name = String()
                while s.more():
                    var k2 = s.varint()
                    if k2 == (1 << 3 | 2):
                        name = s.str()
                    else:
                        s.skip(k2 & 7)
                if f == 11:
                    self.inputs.append(name)
                else:
                    self.outputs.append(name)
            else:
                r.skip(key & 7)


struct Reader[o: Origin](ImplicitlyCopyable):
    """Cursor over a protobuf message span."""

    var b: Span[UInt8, Self.o]
    var p: Int
    var end: Int

    def __init__(out self, b: Span[UInt8, Self.o], p: Int, end: Int):
        self.b = b
        self.p = p
        self.end = end

    def more(self) -> Bool:
        return self.p < self.end

    def varint(mut self) raises -> Int:
        var v = UInt64(0)
        var shift = UInt64(0)
        while True:
            if self.p >= self.end:
                raise Error("onnx: truncated varint")
            var c = self.b[self.p]
            self.p += 1
            v |= UInt64(c & 0x7F) << shift
            if c < 0x80:
                return Int(v)
            shift += 7

    def sub(mut self) raises -> Reader[Self.o]:
        var n = self.varint()
        if self.p + n > self.end:
            raise Error("onnx: truncated field")
        var r = Reader(self.b, self.p, self.p + n)
        self.p += n
        return r

    def str(mut self) raises -> String:
        var s = self.sub()
        return String(StringSlice(unsafe_from_utf8=self.b[s.p : s.end]))

    def fixed32(mut self) raises -> UInt32:
        if self.p + 4 > self.end:
            raise Error("onnx: truncated fixed32")
        var v = UInt32(0)
        for k in range(4):
            v |= UInt32(self.b[self.p + k]) << UInt32(8 * k)
        self.p += 4
        return v

    def skip(mut self, wt: Int) raises:
        if wt == 0:
            _ = self.varint()
        elif wt == 1:
            self.p += 8
        elif wt == 2:
            _ = self.sub()
        elif wt == 5:
            self.p += 4
        else:
            raise Error("onnx: wire type " + String(wt))

    def ints(mut self, wt: Int, mut out: List[Int]) raises:
        """A repeated varint field, packed (wt 2) or not."""
        if wt == 2:
            var s = self.sub()
            while s.more():
                out.append(s.varint())
            self.p = s.end
        else:
            out.append(self.varint())

    def floats(mut self, wt: Int, mut out: List[Float32]) raises:
        if wt == 2:
            var s = self.sub()
            while s.more():
                out.append(bitcast[DType.float32](s.fixed32()))
        else:
            out.append(bitcast[DType.float32](self.fixed32()))


def _tensor(mut r: Reader) raises -> Tensor:
    var t = Tensor()
    var raw_p = -1
    var raw_n = 0
    while r.more():
        var key = r.varint()
        var f = key >> 3
        var wt = key & 7
        if f == 1:
            r.ints(wt, t.dims)
        elif f == 2:
            t.dtype = r.varint()
        elif f == 4:
            r.floats(wt, t.f)
        elif f == 5 or f == 7:
            r.ints(wt, t.i)
        elif f == 8:
            t.name = r.str()
        elif f == 9:
            var s = r.sub()
            raw_p = s.p
            raw_n = s.end - s.p
        else:
            r.skip(wt)
    if raw_p >= 0:
        var p = r.b.unsafe_ptr() + raw_p
        if t.dtype == FLOAT:
            var q = p.bitcast[Float32]()
            t.f = List[Float32](capacity=raw_n // 4)
            for k in range(raw_n // 4):
                t.f.append(q.load[alignment=1](k))
        elif t.dtype == INT64:
            var q = p.bitcast[Int64]()
            for k in range(raw_n // 8):
                t.i.append(Int(q.load[alignment=1](k)))
        else:
            raise Error("onnx: raw_data of dtype " + String(t.dtype) + " in " + t.name)
    return t^


def _node(mut r: Reader) raises -> Node:
    var n = Node()
    while r.more():
        var key = r.varint()
        var f = key >> 3
        var wt = key & 7
        if f == 1:
            n.inputs.append(r.str())
        elif f == 2:
            n.outputs.append(r.str())
        elif f == 3:
            n.name = r.str()
        elif f == 4:
            n.op = r.str()
        elif f == 5:
            var s = r.sub()
            n.attrs.append(_attr(s))
        else:
            r.skip(wt)
    return n^


def _attr(mut r: Reader) raises -> Attr:
    var a = Attr()
    while r.more():
        var key = r.varint()
        var f = key >> 3
        var wt = key & 7
        if f == 1:
            a.name = r.str()
        elif f == 2:
            a.f = bitcast[DType.float32](r.fixed32())
        elif f == 3:
            a.i = r.varint()
        elif f == 4:
            a.s = r.str()
        elif f == 5:
            var s = r.sub()
            a.t.append(_tensor(s))
        elif f == 7:
            r.floats(wt, a.floats)
        elif f == 8:
            r.ints(wt, a.ints)
        else:
            r.skip(wt)
    return a^
