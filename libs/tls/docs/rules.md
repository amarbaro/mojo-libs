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


## Lane 5 (TLS 1.2, net, interop harness)

- `zero = zero or r.u8() == 0` in a `while r.left() > 0` scan never read again once `zero` was true: endless loop on a
  ClientHello. Read into a variable first, then combine. Found by the mutation fuzz, not by review.
- `openssl s_client -no_extended_master_secret` does not exist (it is `-no_ems`): the client printed usage, the "server
  refuses it" check passed for the wrong reason. A negative probe must prove the client really connected and the
  handshake then failed (`refused()` in tests/interop/run.sh).
- A harness is tested against a known good peer before it judges ours: `run.sh peers` found three probe bugs (s_client
  quit on stdin EOF before the reply, curl exits non-zero under `pipefail` after a close without close_notify, a CA SPKI
  pin never matches an unchained leaf in Chromium).
- `vivaldi --headless=new --dump-dom` never exits here: drive it over CDP (tests/interop/browser_probe.py).
- A test must make the condition happen. The first slow-reader test (2 MiB) left the "EPOLLOUT never armed" mutant alive
  because loopback buffers swallowed it; 4 MiB to a 4 KiB receive buffer makes partial writes real.
- An alert code of 0 must not mean "default decode_error" (0 is close_notify): the default is `A_DECODE`, `-1` means
  "the peer sent the alert, send none back".
- Mojo 1.2: `raise` after assigning a field of a field in a raising `__init__` fails to compile ("destroyed out of the
  middle"): do the raising work in `start()`. `ref p = self.tab[fd]` is invalidated by any `mut self` call: index again.
  `List + List` needs implicit copies: use `cat(...)`. `Int(String, base=16)` does not exist: decode nibbles.

## Lane matrix (wave 2)

- Two lane 1 mutants (gcm-noncelen, aes-keylen) were "killed" by SIGILL from a bounds trap, not by a check -> a mutant runner
  counts only a checked error (exit 1, a printed FAIL or a raised Error) as a kill; exit >= 124 (signal, timeout) is a survivor; code clamps its loops so a missed policy check cannot read out of bounds.
- Duplicate lines in tests/mutants_sym.txt ran the same mutant twice in one directory and garbled the log -> mutant names are unique.
- `playwright install chromium` deleted the older chromium, headless-shell and ffmpeg builds from the shared `~/.cache/ms-playwright`
  (it prunes builds "unused" by its own version) -> never run `playwright install` against the shared cache; set
  `PLAYWRIGHT_BROWSERS_PATH=<repo>/.work/...` first, or reuse an installed build read-only.
