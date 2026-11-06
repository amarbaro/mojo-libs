---
name: mojo-uuid
description: UUID for Mojo
metadata:
  version: 0.1.0
---
# mojo-uuid
UUID for Mojo, byte-identical with CPython 3.14 uuid.

## When to use
Generating UUIDs, parsing UUID strings.

## Install
-I src

## Calls
uuid4()
uuid3(NAMESPACE_DNS, "python.org")
uuid5(NAMESPACE_DNS, "python.org")
str(u)
u.hex()
u.bytes()

## Gotchas
Clock seam optional params for testing.
RNG uses getrandom.