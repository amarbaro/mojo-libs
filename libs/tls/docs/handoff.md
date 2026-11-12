# Handoff: wave 2, steps 1-3 (2026-11-12)

## Done (verified)
- Wave 1 merged to master (731b772); all 5 lane gates rerun on merged master: PASS.
- Step 1, TLS 1.3: runs on lane 1/2 crypto; src/tls/tls13/_tmp_crypto deleted (d99beaf). gate_tls13 --mutants: 41 PASS
  incl. 13 openssl interop, 16 mutants killed.
- Step 1, TLS 1.2: src/tls/tls12/realcrypto.mojo (Crypto12 over lanes 1-3, P-256 + RSA keys, chain validation);
  tests/real/real_crypto.mojo deleted; tests/real/build.sh builds on it. lane-3 `load_private_key_der` added.

## Open, in order
1. tests/check.sh: 3 cells `ours/client/p256/*` fail: run.sh passes the test CA (`$C/ca.pem`) as argv[3], but
   RealCrypto.verify only trusts load_system_roots(), so the self-signed test chain is rightly refused. Fix: give
   RealCrypto a roots source (field set by tls_connect / TlsStream, or a PEM path), then rerun tests/check.sh mutants.
   Everything else in that gate passed (t_flow 69, t_hello 37, net.sh, hello_probe, 16 mutants).
2. Remaining shims: src/tls/x509/shim/ (lane 3: hash, hmac, bigint, rsa, ec_ct, p256, p384) and
   src/tls/asym/sha2.mojo (lane 2 interim) -> lane 1/2; rerun gate_x509.sh, gate_asym.sh, mutants_x509.sh.
3. Step 2: lane 3 x509-limbo: 44 invalid chains accepted, 13 valid rejected (tests/limbo_known.txt pins them):
   fix the 44 first (security), then the 13; the gate must fail on any accepted invalid chain.
4. Lane 1 gate: 2 mutants (gcm-noncelen, aes-keylen) are caught by SIGILL, not a printed FAIL: make them print.
5. Step 3: test matrix: tlsfuzzer, testssl, Chromium + Firefox headless, TLS 1.3 + 1.2 x P-256 + RSA x SNI/ALPN.

## How to check
gates: tests/sym_gate.sh, tests/gate_asym.sh, tests/gate_x509.sh (+ tests/mutants_x509.sh), tests/gate_tls13.sh
--mutants, tests/check.sh mutants. Inputs in .work/{vec,vectors,wycheproof,limbo,certs} (copied from lane worktrees).
