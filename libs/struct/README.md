# mojo-struct

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml) [![license](https://img.shields.io/github/license/amarbaro/mojo-libs)](https://github.com/amarbaro/mojo-libs/blob/main/LICENSE) [![conda](https://img.shields.io/badge/conda-mojo--struct-9DAE51)](https://prefix.dev/channels/@amarbaro/amarbaro/packages/mojo-struct)
<!-- /badges -->

```mojo
from pystruct import Struct, Value

def main() raises:
    var s = Struct("<hI")
    var raw = s.pack([Value(-2), Value(7)])
    print(s.unpack(Span(raw))[1].int)
```

Python's `struct` module for Mojo: pack and unpack binary data with CPython 3.14 semantics. Same
format codes, byte orders (`@ = < > !`), native alignment and padding, and the same error texts.
Values are `Value` (int, float, bool, bytes, complex).

## API

| Call | Python equivalent |
|---|---|
| `Struct(fmt)`, `.size` | `struct.Struct(fmt)`, `.size` |
| `.pack(values)`, `.pack_into(buf, offset, values)` | `pack`, `pack_into` |
| `.unpack(buf)`, `.unpack_from(buf, offset)`, `.iter_unpack(buf)` | `unpack`, `unpack_from`, `iter_unpack` |
| `calcsize`, `pack`, `unpack`, ... | the module-level functions |

The import is `pystruct`, so it does not collide with Mojo's `struct` keyword.

## How it is checked

`scripts/ci.sh` runs 7 gates: oracle cases against CPython 3.14 `struct`, golden bytes, round trip,
mutants (each planted bug must fail a gate), API, the quickstart, and the docs examples.

## Limits

- Needs Mojo 1.2 (`mojo>=1.2.0,<1.3`); `scripts/ci.sh` sets it up with `uv`.
- Values go through a `Value` list, so each unpack allocates one list.

## License

Apache-2.0 (`LICENSE`).
