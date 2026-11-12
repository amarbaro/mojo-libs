# Handoff: wave 2, steps 1-3 (2026-11-12)

## Done (verified)
- Wave 1 merged to master (731b772); all 5 lane gates rerun on merged master: PASS.
- Step 1, TLS 1.3: runs on lane 1/2 crypto; src/tls/tls13/_tmp_crypto deleted (d99beaf). gate_tls13 --mutants: 41 PASS
  incl. 13 openssl interop, 16 mutants killed.
- Step 1, TLS 1.2: src/tls/tls12/realcrypto.mojo (Crypto12 over lanes 1-3, P-256 + RSA keys, chain validation);
  tests/real/real_crypto.mojo deleted; tests/real/build.sh builds on it. lane-3 `load_private_key_der` added.

## Open, in order
1. Step 2: lane 3 x509-limbo: 43 invalid chains accepted, 13 valid rejected (tests/limbo_known.txt pins them):
   fix the 44 first (security), then the 13; the gate must fail on any accepted invalid chain.
2. (done, lane matrix) Lane 1 gate: aes-keylen / gcm-noncelen print FAIL; runners treat exit >= 124 as a survivor.
3. (done, lane matrix) `tests/matrix.sh`: 149 PASS, 13 SKIP with reasons, 0 FAIL (report: .work/report-w2-matrix.md).
4. Promote `tests/matrix/msrv.mojo` (TLS 1.3/1.2 dispatch on one port) into `src/tls/net`: `TlsServer` is TLS 1.2 only.
5. Lane 2: asym mutant 17 (rsa.mojo length check) dies of SIGILL only (`tests/mutants_asym.sh` prints TRAP).
6. NewSessionTicket / resumption (tlsfuzzer lengths, record-layer-limits need it), client certificates, secp384r1/x448 groups in 1.3.

## How to check
gates: tests/matrix.sh (+ tests/matrix/build.sh), tests/sym_gate.sh, tests/gate_asym.sh, tests/gate_x509.sh (+ tests/mutants_x509.sh), tests/gate_tls13.sh
--mutants, tests/check.sh mutants. Inputs in .work/{vec,vectors,wycheproof,limbo,certs} (copied from lane worktrees).
