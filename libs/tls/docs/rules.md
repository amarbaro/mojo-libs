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
