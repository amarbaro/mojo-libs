# mojo-tls: TLS 1.3 and 1.2, client and server, pure Mojo

Goal: serve HTTPS to every current browser and talk HTTPS to any server, with no C library, at the fewest lines
that pass the gates below. Performance target: within 2x of OpenSSL on bulk transfer and handshakes per second.

## References (read, never depended on)

| Repo | Licence | Use |
|---|---|---|
| `~/Projects/imports/tls-refs/Mosaad-M-tls` | MIT | Pure-Mojo crypto and a TLS 1.3/1.2 client (30k lines with tests). Map of what works, test layout, ct_check bench, known holes (issuer-is-CA bug before 1.4.3). Code may be ported with its MIT notice in the file header. |
| `nsalerni-mojo-tls` | Apache-2.0 | OpenSSL wrapper: API shape for a nonblocking server, compliance tools list (resume, shutdown, error queue). |
| `corv89-mojo-tls` | none | Read only: listener/config API ideas. No code copied. |

Our own code to reuse: `mojo-hashlib` (SHA-256/SHA-1 compression), `mojo-aio` (epoll Loop, tcp_listen, accept,
read, write), `mojo-bento` (HTTP/1.1 on top), `mojo-proptest` (property tests), `mojo-bench`.

## Scope: the browser matrix decides

Chrome, Edge, Firefox, Safari (2024+), curl, Python ssl, Go, OpenSSL s_client all negotiate with this set:

| Item | TLS 1.3 | TLS 1.2 (fallback for old clients) |
|---|---|---|
| Cipher suites | TLS_AES_128_GCM_SHA256 (mandatory), TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256 | ECDHE_ECDSA/RSA_WITH_AES_128_GCM_SHA256, _AES_256_GCM_SHA384, _CHACHA20_POLY1305_SHA256 |
| Key exchange | x25519, secp256r1, secp384r1, x448 (server order x25519 > P-256 > P-384 > x448); HelloRetryRequest when the client offered none of the key shares | x25519, secp256r1, secp384r1 |
| Server certificate keys | ECDSA P-256 (preferred, fast), RSA 2048+ (rsa_pss_rsae_sha256 signatures) | ECDSA P-256, RSA (PKCS#1 v1.5 + PSS) |
| Extensions | SNI, ALPN (http/1.1, h2 name only), supported_versions, key_share, signature_algorithms, psk_key_exchange_modes (tickets later), record_size_limit | SNI, ALPN, extended_master_secret, renegotiation_info (refuse renegotiation), ec_point_formats |

Out: TLS 1.0/1.1 (browsers removed them in 2020), CBC suites, RSA key exchange, static DH, renegotiation,
compression, 0-RTT. Later, separate pieces: X25519MLKEM768 hybrid (Chrome/Firefox default now, clients fall back
to x25519 without it), OCSP stapling. Client certificates: wave 3b, done. Session tickets and psk_dhe_ke resumption: wave 3a, done.

## Pieces, lines, gates

| Lane | Piece | Target lines | Gate (must pass; a mutant per gate must fail) |
|---|---|---|---|
| 1 | Symmetric: SHA-256/384/512, HMAC, HKDF (RFC 5869), TLS 1.2 PRF, AES-128/256 (AES-NI via LLVM intrinsics + constant-time software fallback), GCM (PCLMUL GHASH), ChaCha20, Poly1305, AEAD wrappers | 1300 | NIST CAVP + Wycheproof vectors (aes_gcm, chacha20_poly1305, hkdf, hmac), RFC 5869/7539/8439 vectors; `openssl enc`/`dgst` as a random-input oracle; >= 1 GB/s AES-128-GCM with AES-NI |
| 2 | Asymmetric: X25519 (RFC 7748), P-256 ECDH + ECDSA sign/verify (constant-time scalar mult, RFC 6979 deterministic nonces), P-384 verify, RSA verify (PKCS#1 v1.5, PSS) + RSA-PSS sign with CRT and blinding | 1600 | Wycheproof (x25519, ecdh_secp256r1, ecdsa_secp256r1_sha256, rsa_pss, rsa_signature) all PASS; `openssl pkeyutl`/`dgst -sign` cross-check; dudect-style timing check on scalar mult and RSA sign |
| 3 | ASN.1 DER reader, PEM, X.509 v3 (names, SAN, basicConstraints, keyUsage, EKU, validity), chain path validation against the system CA bundle, private keys (PKCS#8, SEC1, PKCS#1) | 1000 | Every cert in /etc/ssl/certs parses; x509-limbo or BetterTLS-style cases (issuer-is-CA, pathLen, name constraints DNS/IP, expired, wrong EKU) give the right verdict; keys from `openssl genpkey` load and sign verifiably |
| 4 | TLS 1.3: record layer (AEAD, sequence numbers, padding, record_size_limit), handshake messages encode/decode, key schedule (RFC 8446 7.1), client and server state machines, HRR, KeyUpdate, alerts, close_notify | 1500 | RFC 8448 example traces reproduced byte for byte (simple 1-RTT, HRR, ChaCha); interop: our server <-> `openssl s_client`, curl, Python; our client <-> `openssl s_server` and public sites; tlsfuzzer TLS 1.3 scripts |
| 5 | TLS 1.2 (RFC 5246 + 7627 EMS + 8422 ECDHE) client and server; nonblocking `TlsServer` on mojo-aio with SNI cert selection, ALPN, timeouts, size limits; `https` example on mojo-bento; browser tests | 900 | openssl `-tls1_2` both ways; Chromium (Vivaldi headless via cdp-headless) and Firefox headless load a page from our server; qualys-style self-scan (`testssl.sh` if present) shows only the suites above; 10k handshakes/s target on 8 cores |

Total target: about 6300 lines (Mosaad's client alone is about 13k without tests). Lines are measured with mokei.

## Security rules (every lane)

- Constant time on secrets: no branch or table index on key, nonce, scalar or plaintext-derived values; AES
  software path is bitsliced or uses no S-box lookups; GHASH without tables when PCLMUL is absent.
- Every length from the peer is checked before allocating or indexing; maximum record 2^14 + 256; handshake
  message cap 64 KiB; certificate chain cap 10 entries.
- Every parser is fuzzed (random and mutated vectors, `mojo-proptest`) and never crashes or hangs.
- Secrets are zeroed when a connection closes. No secret ever printed or logged.
- An internal review lane (opus, frame-blind) reads each lane before merge; an external audit before any public use.

## Performance rules

Flat byte buffers, no per-record allocation, AEAD in place, SIMD for ChaCha20/Poly1305, AES-NI + PCLMUL for GCM,
precomputed fixed-base tables for P-256 signing, one resident process per benchmark. Numbers in every commit.

## Dispatch

Wave 1 (this workflow): 5 lanes in parallel, each a haiku researcher then a sonnet builder.
- The haiku writes `.work/dossier-<lane>.md`: the exact RFC sections and test-vector sources, where each function
  lives in the reference repos (file:line), what our code already has, and every known pitfall from the reference
  repos' commit history and issues.
- The sonnet builds its piece in `src/tls/` from its brief plus the dossier, commits by pathspec on its own branch
  `lane-<n>` (worktree), and ends with the gate output in `.work/report-<lane>.md`.
Lane 4 and 5 start with the parts that need no crypto (codecs, state machines with test vectors from RFC 8448 and
captured handshakes) and use lane 1-2 interfaces declared in `docs/api.md`.
Wave 2 (next): integration, interop matrix, browsers, review lane, then performance.
