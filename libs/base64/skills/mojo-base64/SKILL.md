---
name: mojo-base64
description: Base16/32/64 encode and decode matching CPython base64.
metadata:
  version: 0.1.0
---

# mojo-base64

Use for base64, base32, base32hex, base16 encode/decode.

## Install

`-I src` from a clone.

## Calls

- b64encode(s) -> List[Byte]
- b64decode(s, altchars, validate)
- standard_b64encode / standard_b64decode
- urlsafe_b64encode / urlsafe_b64decode
- b32encode / b32decode(casefold, map01)
- b32hexencode / b32hexdecode(casefold)
- b16encode / b16decode(casefold)

## Gotchas

altchars empty means None; len != 2 raises.
validate=True enables strict mode.
casefold defaults False.
map01 length must be 1.

## Gate

`scripts/check.sh`
