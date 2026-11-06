# API
struct UUID(value: UInt128)
  int() UInt128
  __str__() String
  hex() String
  urn() String
  bytes() Array
  variant() String
  version() Int
  time_low() UInt32
  time_mid() UInt16
  time_hi_version() UInt16
  clock_seq_hi_variant() UInt8
  clock_seq_low() UInt8
  clock_seq() Int
  node() UInt64
  time() UInt64
def uuid3(namespace: UUID, name: String) raises -> UUID
def uuid4() raises -> UUID
def uuid5(namespace: UUID, name: String) raises -> UUID
def uuid6(node: UInt64=0, clock_seq: Int=-1, timestamp_ns: Int=-1) raises -> UUID
def uuid7(timestamp_ms: Int=-1) raises -> UUID
def uuid8(a: Int=-1, b: Int=-1, c: Int=-1) raises -> UUID
constants NAMESPACE_DNS, NAMESPACE_URL, NAMESPACE_OID, NAMESPACE_X500, NIL, MAX
Raises: ValueError messages per CPython.