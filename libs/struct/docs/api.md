# API

```mojo
from pystruct import Struct, Value, Complex, Bytes, OVERFLOW, calcsize, pack, pack_into, unpack, unpack_from, iter_unpack
```

The import is `pystruct`. Every call raises `Error` with the text CPython's `struct` gives.

## `Struct(format)`

A compiled format, as CPython's `struct.Struct`. Parse errors raise (`bad char in struct format`,
`repeat count given without format specifier`, `total struct size too long`).

| Member | What |
|---|---|
| `size` (and `len(s)`) | packed size in bytes |
| `pack(values: List[Value]) -> Bytes` | one `Value` per item; a wrong count raises |
| `pack_into(mut buf: Bytes, offset, values)` | writes into `buf` at `offset` (a negative offset counts from the end, as in CPython); zeroes the target bytes first; raises when the buffer is too small |
| `unpack(buf: Span[UInt8]) -> List[Value]` | `buf` must be exactly `size` bytes |
| `unpack_from(buf: Span[UInt8], offset=0) -> List[Value]` | reads `size` bytes at `offset` |
| `unpack_from_into(buf, offset, mut out: List[Value])` | as `unpack_from`, into a caller list: `out` is cleared and its capacity kept, so a loop allocates nothing per row |
| `iter_unpack(buf: Span[UInt8]) -> List[List[Value]]` | every `size`-byte record. Returns a list, where CPython returns an iterator. Raises for size 0 or a buffer length that is not a multiple of `size` |

## `Value`

One packed or unpacked item: a tagged struct, not a `Variant`.

- `kind`: one of `Value.INT`, `Value.FLOAT`, `Value.BOOL`, `Value.BYTES`, `Value.COMPLEX`.
- `int: Int128` (INT, and BOOL as 0 or 1), `re`, `im` (FLOAT uses `re`; COMPLEX uses both), `bytes: Bytes` (BYTES).
- Implicit constructors from `Int128`, `Int`, `Float64`, `Bool`, `Bytes` and `Complex`.

## `Complex(re, im)`

`Float64` real and imaginary parts, for the `F` and `D` codes.

## `Bytes`

`comptime Bytes = List[UInt8]`.

## `OVERFLOW`

`"OverflowError: "`, the prefix of the errors CPython raises as `OverflowError` rather than `struct.error`.

## Module functions

`calcsize(format)`, `pack(format, values)`, `pack_into(format, buf, offset, values)`,
`unpack(format, buf)`, `unpack_from(format, buf, offset=0)`, `iter_unpack(format, buf)`.
Each compiles `Struct(format)` on every call; keep a `Struct` in a loop.
