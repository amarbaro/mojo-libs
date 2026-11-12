# Rules (what broke -> the rule)

- `x = f(Span(x))` with x a List returned a wrong value (TLS PRF A(2) came out as A(1)) -> never assign a call result over the list its Span borrows from: compute into a temp (`var nx = f(a); a = nx^`).
- SHA-512/384 padding left the 0x80 byte inside the 16-byte length field when the message length was 112..119 mod 128 -> clear the whole block before writing the length, then test every length 0..139 against an oracle.
- A mutant regex containing `|` split on the mutant file's `|` separator and ran as a different mutant -> the separator is `@`; write a literal `|` as `[|]`.
- OpenSSL's `enc -chacha20` carries a counter wrap into the nonce word, RFC 8439 leaves it undefined -> keep oracle messages below 2^32 blocks.
- `Span[UInt8, _]` parameters infer a mutable origin from a `List` argument and reject the same list twice -> declare read-only inputs as `Span[UInt8, ImmutAnyOrigin]`.
- A generic over a trait whose methods hold a value needs `Deinitable` on the trait, not `Movable`.
