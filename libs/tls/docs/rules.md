# Rules (what broke -> the rule)

- `x = f(Span(x))` with x a List returned a wrong value (TLS PRF A(2) came out as A(1)) -> never assign a call result over the list its Span borrows from: compute into a temp (`var nx = f(a); a = nx^`).
- SHA-512/384 padding left the 0x80 byte inside the 16-byte length field when the message length was 112..119 mod 128 -> clear the whole block before writing the length, then test every length 0..139 against an oracle.
- A mutant regex containing `|` split on the mutant file's `|` separator and ran as a different mutant -> the separator is `@`; write a literal `|` as `[|]`.
- OpenSSL's `enc -chacha20` carries a counter wrap into the nonce word, RFC 8439 leaves it undefined -> keep oracle messages below 2^32 blocks.
- `Span[UInt8, _]` parameters infer a mutable origin from a `List` argument and reject the same list twice -> declare read-only inputs as `Span[UInt8, ImmutAnyOrigin]`.
- A generic over a trait whose methods hold a value needs `Deinitable` on the trait, not `Movable`.

# Rules learned (what broke -> the rule)

Lane 4 (TLS 1.3), 2026-11-12. Other lanes append their own lines; concatenate on merge.

- A sed rewrite of `crypto.` in the ported Mosaad files also renamed the `llvm.aarch64.crypto.aese` intrinsics -> rewrite
  only the leading `from`/`import` lines (`tools/port_tmp_crypto.sh`), then diff the result against the source.
- A test whose expected value is computed by the code under test (CertificateVerify content) let a mutant of that code
  survive -> write the expected bytes out by hand in the test and add an independent oracle (openssl verifies the RFC 8448
  signature over our content).
- A mutant of the Finished check survived because every test fed valid input -> each verification gets a test that feeds
  the same message with one bit flipped and checks the alert on the wire.
- A plaintext record arriving after the traffic keys were installed went to the AEAD (wrong alert) -> check the outer type
  before decrypting; found by the loopback gate, not by the RFC traces.
- The interop client closed stdin right after its request, so close_notify overtook the echo; RFC 8446 6.1 makes the
  receiver close at once and drop pending writes -> harnesses wait for the reply before closing.
- A generic struct parameter needs `trait X(Movable, Deinitable)` on this Mojo, otherwise "field has non-'Deinitable' type".
- Parallel lanes load the box (load average 50+): numbers are best of N rounds, never a single run.
