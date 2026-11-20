# Brief: security audit of mojo-tls (codex lane tls-audit), read-only

Repo `~/Projects/mojo/mojo-tls`: pure-Mojo TLS 1.3 + 1.2 client/server, x509, own crypto (AES-GCM, ChaCha20-Poly1305, x25519, x448, P-256, P-384, ECDSA, RSA verify, SHA-2, HKDF). Read `README.md`, `SECURITY.md`, `docs/api.md`, `docs/design.md`, `docs/rules.md`, `docs/lanes/FINDING-heap-grow.md` (a use-after-free just found and fixed: same class may exist elsewhere).

Do NOT edit any file outside `docs/lanes/AUDIT.md`. Do not commit. Another lane and the driver are changing `src/` right now; audit what is on disk.

## Look for, with file:line and a concrete trigger for each
1. Memory safety: pointers laundered through `Int(...)`/`unsafe_ptr()` whose owner may be dropped before use (the fixed bug's class), out-of-bounds reads/writes on peer-controlled lengths, unchecked `external_call` memcpy sizes, integer overflow in length math.
2. Protocol state machine: messages accepted in the wrong state, missing transcript coverage, downgrade (1.3 -> 1.2 sentinel, version negotiation), renegotiation, early data, HelloRetryRequest handling, key update limits, alert handling, close_notify / truncation.
3. Crypto: constant-time violations on secret data (branches, table lookups, early-exit compares on MAC/tag/padding), nonce reuse, sequence number wrap, key schedule errors, RSA/ECDSA verify edge cases (low-s, point at infinity, invalid curve points, small-subgroup on x25519/x448 all-zero check), RNG source and failure handling.
4. x509 / chain validation: name matching (wildcards, IDNA, IP SANs), basicConstraints, keyUsage/EKU, pathLen, expiry, critical extensions, signature algorithm confusion, chain length / depth limits, parser DoS.
5. Resumption tickets: ticket key handling, binder check, replay, lifetime; client certificates: CertificateVerify, state.
6. DoS: allocation driven by peer lengths, unbounded buffers, CPU (huge RSA exponents, many records).
7. API misuse traps: insecure defaults, verify off by default, hostname not checked unless set.

Use the existing tests and tools to back a claim where cheap (e.g. build and run a small repro under `.work/audit/`); say UNVERIFIED for any claim without a trigger you ran.

## Output `docs/lanes/AUDIT.md`
Table first: `severity (critical/high/medium/low/info) | area | file:line | finding | trigger | verified yes/no | fix sketch`, sorted by severity. Then a short section per critical/high finding. Then "checked and found sound" (one line each), so coverage is visible.

Done: `herd tell wXG:p3 'DONE tls-audit -> docs/lanes/AUDIT.md (<crit>/<high>/<med>/<low>)'`. Stuck: `herd tell wXG:p3 'QUESTION tls-audit: ...'`.
