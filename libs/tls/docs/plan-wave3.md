# Wave 3 plan: resumption, client certificates, more groups (2026-11-12)

Goal of the repo (docs/plan.md:3) is reached by wave 2 + the orchestrator's items (dual 1.3/1.2 server in `src/tls/net`,
asym mutant 17, TWCA anchor). Wave 3 adds what tlsfuzzer/testssl SKIP today. One Sonnet lane, order 3c -> 3a -> 3b,
fewest lines that pass the gates (docs/lanes/common.md).

## 3c groups (M, est. 80-200 LOC)
- secp384r1 key share in TLS 1.3 (and ECDHE in 1.2 if the suite list allows): `asym/ec.mojo` already has `p384()` (`:60`) and
  `p384_verify` (`:399`); add ECDH on P-384 (scalar mult on the generic `Curve[6]`), group id 0x0018 in `tls13/messages.mojo`,
  server/client selection order x25519 > P-256 > P-384 > x448. KATs: RFC 5903 / Wycheproof ecdh_secp384r1 (`.work/wycheproof`).
- x448 (RFC 7748): new `asym/x448.mojo` beside `x25519.mojo` (same ladder on a 448-bit field), group id 0x001e. KATs: RFC 7748 6.2 +
  Wycheproof x448. Constant time (tests/ct.mojo pattern).
- Done: tlsfuzzer cells that SKIP for secp384r1/x448 move to PASS; `tests/matrix/tf_xfail.txt` loses those lines.

## 3a session resumption, TLS 1.3 (L, est. 250-400 LOC)
- Server: NewSessionTicket after the handshake (RFC 8446 4.6.1): ticket = AEAD(ticket_key, resumption secret + age_add + expiry +
  suite + ALPN); `keysched.mojo:77` already takes a PSK. Accept `pre_shared_key` + `psk_key_exchange_modes` (psk_dhe_ke only),
  verify the binder (4.2.11.2) in constant time, reject on age/expiry/suite mismatch -> full handshake (never fail open).
- No 0-RTT (early_data refused). Ticket key rotation: two keys, config field.
- Client: store a ticket, offer it on reconnect.
- Done: tlsfuzzer `test-tls13-lengths`, record-layer-limits 'max size of Finished', `test-tls13-session-resumption` (if present) PASS;
  openssl `s_client -sess_out/-sess_in` resumes (`Reused, TLSv1.3`); a forged binder and an expired ticket fall back to full handshake (tests).

## 3b client certificates (L, est. 200-300 LOC)
- Server option `require_client_cert` + trust roots for clients: TLS 1.3 CertificateRequest (4.3.2), verify client Certificate with
  the x509 chain code (clientAuth EKU), CertificateVerify with the client context string; TLS 1.2 CertificateRequest + CertificateVerify.
- Client: present a configured certificate + key when asked (today `tls12/client.mojo:4` treats CertificateRequest as fatal).
- Done: openssl `s_client -cert/-key` accepted, missing or untrusted cert refused with the right alert (certificate_required 116 in 1.3);
  tlsfuzzer `test-tls13-ecdsa-in-certificate-verify` and client-cert scripts move from SKIP to PASS.

## Gates for every step (merged tree)
tests/sym_gate.sh, tests/gate_asym.sh, tests/gate_x509.sh + mutants_x509.sh, tests/gate_tls13.sh --mutants, tests/check.sh,
tests/matrix.sh (every tlsfuzzer case; a Chromium ERR_NETWORK_CHANGED cell is retried once, rules.md). New code gets mutants in
the matching mutants file; every new parser is fuzzed (tests/fuzz.mojo).
