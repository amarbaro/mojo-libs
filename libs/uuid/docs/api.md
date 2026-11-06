# API
struct UUID(value: UInt128)
  int() UInt128; __str__() String; hex() String; urn() String; bytes() Array; variant() String; version() Int
  time_low/time_mid/time_hi_version/clock_seq_hi_variant/clock_seq_low/clock_seq/node/time
def uuid3(namespace: UUID, name: String) raises -> UUID
def uuid4() raises -> UUID
def uuid5(namespace: UUID, name: String) raises -> UUID
def uuid6(node: UInt64=0, clock_seq: Int=-1, timestamp_ns: Int=-1) raises -> UUID
def uuid7(timestamp_ms: Int=-1) raises -> UUID
def uuid8(a: Int=-1, b: Int=-1, c: Int=-1) raises -> UUID
constants NAMESPACE_DNS, NAMESPACE_URL, NAMESPACE_OID, NAMESPACE_X500, NIL, MAX
Raises: ValueError messages per CPython.