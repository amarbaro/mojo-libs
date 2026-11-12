# Rules (what broke -> the rule)

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
