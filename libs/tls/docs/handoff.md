# Handoff: wave 2, steps 1-3 (2026-11-12)

## Done (verified)
- Wave 1 merged to master (731b772); all 5 lane gates rerun on merged master: PASS.
- Step 1, TLS 1.3: runs on lane 1/2 crypto; src/tls/tls13/_tmp_crypto deleted (d99beaf). gate_tls13 --mutants: 41 PASS
  incl. 13 openssl interop, 16 mutants killed.
- Step 1, TLS 1.2: src/tls/tls12/realcrypto.mojo (Crypto12 over lanes 1-3, P-256 + RSA keys, chain validation);
  tests/real/real_crypto.mojo deleted; tests/real/build.sh builds on it. lane-3 `load_private_key_der` added.

## Open, in order
1. (done, merged) Step 2 x509-limbo: invalid accepted 44 -> 9 (webpki::cn policy pins only), valid rejected 13 -> 8; the gate fails
   on any other disagreement (.work/report-w2-x509.md, docs/x509.md). Open: TWCA Global Root CA refused (no SKI), user call.
2. (done, merged) Lane 1 gate: aes-keylen / gcm-noncelen print FAIL; runners treat exit >= 124 as a survivor.
3. (done, merged) `tests/matrix.sh`: 149 PASS, 13 SKIP with reasons, 0 FAIL (report: .work/report-w2-matrix.md).
4. (done) `TlsServer` serves TLS 1.3 and 1.2 on one port; `tests/matrix/msrv.mojo` runs on it, so the matrix tests the product: pass=149 skip=13 fail=0.
5. (done, facbc06) asym mutant 17 is killed by a printed FAIL; MUTANT_STRICT=1 gate_asym passes.
6. NewSessionTicket / resumption (tlsfuzzer lengths, record-layer-limits need it), client certificates, secp384r1/x448 groups in 1.3.

## How to check
gates: tests/matrix.sh (+ tests/matrix/build.sh), tests/sym_gate.sh, tests/gate_asym.sh, tests/gate_x509.sh (+ tests/mutants_x509.sh), tests/gate_tls13.sh
--mutants, tests/check.sh mutants. Inputs in .work/{vec,vectors,wycheproof,limbo,certs} (copied from lane worktrees).
