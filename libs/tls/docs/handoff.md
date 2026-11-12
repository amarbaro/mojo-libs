# Handoff: wave 2, steps 1-3 (2026-11-12)

## Done (verified)
- Wave 1 merged to master (731b772); all 5 lane gates rerun on merged master: PASS.
- Step 1, TLS 1.3: runs on lane 1/2 crypto; src/tls/tls13/_tmp_crypto deleted (d99beaf). gate_tls13 --mutants: 41 PASS
  incl. 13 openssl interop, 16 mutants killed.
- Step 1, TLS 1.2: src/tls/tls12/realcrypto.mojo (Crypto12 over lanes 1-3, P-256 + RSA keys, chain validation);
  tests/real/real_crypto.mojo deleted; tests/real/build.sh builds on it. lane-3 `load_private_key_der` added.

## Open, in order
1. Step 2 DONE on branch lane-w2-x509 (not merged): limbo invalid accepted 44 -> 9 (webpki::cn policy pins only), valid rejected 13 -> 8;
   the gate fails on any other disagreement. See .work/report-w2-x509.md and docs/x509.md.
2. Lane 1 gate: 2 mutants (gcm-noncelen, aes-keylen) are caught by SIGILL, not a printed FAIL: make them print.
3. Step 3: test matrix: tlsfuzzer, testssl, Chromium + Firefox headless, TLS 1.3 + 1.2 x P-256 + RSA x SNI/ALPN.

## How to check
gates: tests/sym_gate.sh, tests/gate_asym.sh, tests/gate_x509.sh (+ tests/mutants_x509.sh), tests/gate_tls13.sh
--mutants, tests/check.sh mutants. Inputs in .work/{vec,vectors,wycheproof,limbo,certs} (copied from lane worktrees).
