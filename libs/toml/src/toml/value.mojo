from std.memory import ArcPointer

comptime KIND_STRING: Int = 0
comptime KIND_INTEGER: Int = 1
comptime KIND_FLOAT: Int = 2
comptime KIND_BOOL: Int = 3
comptime KIND_DATETIME: Int = 4
comptime KIND_ARRAY: Int = 5
comptime KIND_TABLE: Int = 6

comptime DATETIME_OFFSET: Int = 0
comptime DATETIME_LOCAL: Int = 1
comptime DATE_LOCAL: Int = 2
comptime TIME_LOCAL: Int = 3


struct TomlNode(Copyable, Movable):
    var kind: Int
    var s: String
    var i: Int64
    var f: Float64
    var b: Bool
    var dt_kind: Int
    var arr: List[Int]
    var is_aot: Bool
    var tkeys: List[String]
    var tvals: List[Int]
    var header_closed: Bool
    var dotted_closed: Bool
    var inline_closed: Bool

    def __init__(out self):
        self.kind = KIND_STRING
        self.s = ""
        self.i = 0
        self.f = 0.0
        self.b = False
        self.dt_kind = 0
        self.arr = []
        self.is_aot = False
        self.tkeys = []
        self.tvals = []
        self.header_closed = False
        self.dotted_closed = False
        self.inline_closed = False

    def find_key(self, key: String) -> Int:
        for idx in range(len(self.tkeys)):
            if self.tkeys[idx] == key:
                return self.tvals[idx]
        return -1


struct TomlDoc(Copyable, Movable):
    var pool: List[TomlNode]

    def __init__(out self):
        self.pool = []

    def push(mut self, var n: TomlNode) -> Int:
        self.pool.append(n^)
        return len(self.pool) - 1


struct TomlValue(Copyable, Movable):
    var doc: ArcPointer[TomlDoc]
    var idx: Int

    def __init__(out self, doc: ArcPointer[TomlDoc], idx: Int):
        self.doc = doc
        self.idx = idx

    def kind(self) -> Int:
        return self.doc[].pool[self.idx].kind

    def is_table(self) -> Bool:
        return self.kind() == KIND_TABLE

    def is_array(self) -> Bool:
        return self.kind() == KIND_ARRAY

    def is_string(self) -> Bool:
        return self.kind() == KIND_STRING

    def is_integer(self) -> Bool:
        return self.kind() == KIND_INTEGER

    def is_float(self) -> Bool:
        return self.kind() == KIND_FLOAT

    def is_bool(self) -> Bool:
        return self.kind() == KIND_BOOL

    def is_datetime(self) -> Bool:
        return self.kind() == KIND_DATETIME

    def as_string(self) raises -> String:
        if self.kind() != KIND_STRING:
            raise Error("toml: value is not a string")
        return self.doc[].pool[self.idx].s

    def as_int(self) raises -> Int64:
        if self.kind() != KIND_INTEGER:
            raise Error("toml: value is not an integer")
        return self.doc[].pool[self.idx].i

    def as_float(self) raises -> Float64:
        if self.kind() != KIND_FLOAT:
            raise Error("toml: value is not a float")
        return self.doc[].pool[self.idx].f

    def as_bool(self) raises -> Bool:
        if self.kind() != KIND_BOOL:
            raise Error("toml: value is not a boolean")
        return self.doc[].pool[self.idx].b

    def as_datetime_text(self) raises -> String:
        if self.kind() != KIND_DATETIME:
            raise Error("toml: value is not a datetime")
        return self.doc[].pool[self.idx].s

    def datetime_kind(self) raises -> Int:
        if self.kind() != KIND_DATETIME:
            raise Error("toml: value is not a datetime")
        return self.doc[].pool[self.idx].dt_kind

    def len(self) -> Int:
        var n = self.doc[].pool[self.idx].copy()
        if n.kind == KIND_ARRAY:
            return len(n.arr)
        if n.kind == KIND_TABLE:
            return len(n.tkeys)
        return 0

    def __getitem__(self, i: Int) raises -> TomlValue:
        var n = self.doc[].pool[self.idx].copy()
        if n.kind != KIND_ARRAY:
            raise Error("toml: value is not an array")
        if i < 0 or i >= len(n.arr):
            raise Error("toml: array index out of range")
        return TomlValue(self.doc, n.arr[i])

    def __getitem__(self, key: String) raises -> TomlValue:
        var opt = self.get(key)
        if not opt:
            raise Error("toml: key not found: " + key)
        return opt.value().copy()

    def get(self, key: String) -> Optional[TomlValue]:
        var n = self.doc[].pool[self.idx].copy()
        if n.kind != KIND_TABLE:
            return None
        var i = n.find_key(key)
        if i < 0:
            return None
        return TomlValue(self.doc, i)

    def keys(self) -> List[String]:
        var n = self.doc[].pool[self.idx].copy()
        var out: List[String] = []
        for k in n.tkeys:
            out.append(k)
        return out^

    def contains(self, key: String) -> Bool:
        var n = self.doc[].pool[self.idx].copy()
        return n.find_key(key) >= 0
