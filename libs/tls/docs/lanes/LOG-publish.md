# LOG tls-pub (publish lane), 2026-11-12

## Committed (master)
- 9fc45d2 build: portable gate scripts (MOJO=$PWD/.venv/bin/mojo, AIO=.work/deps/mojo-aio/src), scripts/deps.sh (mojo-aio pinned 7b2dba7 = v0.1.1), examples/{server,client}.mojo, scripts/example.sh (PASS: TLS 1.3 client, TLS 1.2 openssl, wrong host refused), .gitignore .claude exchange/
- LICENSE (Apache-2.0) + NOTICE (Mosaad-M-tls MIT, PSL MPL-2.0, Wycheproof, limbo, RFC vectors, GPL tools run not shipped)
- fix(tests): bench_tls13 builds again
- Gates run once on c2216c7 + scripts edit, all PASS: sym vec 3s, asym 54s, x509 13s, tls13 33s, check.sh 66s (no mutants), example.sh. Receipts .work/pub/*.out

## UNCOMMITTED, UNVERIFIED (src changed => full matrix + ct + gates before commit)
1. `dup()` in src/tls/sym/aead.mojo, used in tls13/record.mojo open, tls13/conn.mojo, tls12/realcrypto.mojo seal/open (memcpy instead of List(Span) byte loop, was 26.5% of cycles in bench_tls13).
   Measured, taskset -c 5, alternating, medians of 5: AES-128-GCM record open 2161 -> 5373 MB/s, ChaCha20 open 1166 -> 1669, total cycles 5.84G -> 4.35G (corewait). Binaries in .work/prof/{before,after1,after2}-bench_*.
2. record.mojo seal: unsafe_uninit_length body + zero only padding: seal 4943 -> 5033 MB/s (+1.8%).
3. conn.mojo send_app: capacity estimate counts per-record overhead (was len+64, forced a realloc of the whole buffer on record 64).
4. tests/heap_xfer.mojo (heaptide workload, still has debug prints: remove).

## OPEN FINDING (chase first)
Under `heaptide run` (LD_PRELOAD allocator) tests/heap_xfer (1 MiB client->server through Client13/Server13) fails: server says bad_record_mac on the LAST record of a 1 MiB feed (before AND after my edits: pre-existing); with the send_app capacity fix it SEGFAULTS in srv.feed instead. Native glibc run (also MALLOC_PERTURB_=165) passes. 256 KiB passes. Either latent memory bug in RecordReader/List.extend path on big buffers or a heaptide shim bug. Next: reproduce with valgrind/ASan-less probes (feed in 64 KiB chunks, vary size), decide library vs shim; if shim, extend heaptide (own repo, own commit, own test) per BRIEF-publish-profile item 5.

## Not done yet
README, recipe.yaml/pyproject.toml/rattler-build (rattler-build 0.76.1 via pixi global), skills/mojo-tls/SKILL.md, docs/{design,perf,releases/v0.1.0}.md, CHANGELOG, release-note + tag v0.1.0, ci.yml + scripts/ci.sh (fast gates: sym vec, asym (needs wycheproof clone), x509 (limbo via gh), tls13, check.sh, example.sh), size/export (git tracked = 3 MB, .git 10M; 869M is untracked .work/.claude), clean-publish scan (home path in tests only after my edit; author = dev@amarbaro.org only), publish-purge export, gitleaks, corewait/heaptide tables in docs/perf.md, wavewait N/A line, rule lines in docs/rules.md.
Facts for README: matrix pass=176 skip=11 fail=0; gate_tls13 43 mutants killed; test_conn 206, t_flow 78, test_clientauth 29; Wycheproof x448 510/510, ecdh_secp384r1 790/790, x25519 518/518, ecdh P-256 355/355; x509-limbo 9748 cases 9730 agree (10 invalid accepted pinned policy, 8 valid rejected); 118/118 system roots parse; src 16709 lines; bench (core 5): x25519 70us, P-256 sign 146us/verify 187us/ecdh 134us, P-384 verify 530us, AES-128-GCM seal 6.6 GB/s, AES-256 5.7, ChaCha20-Poly1305 1.76, 3052 in-memory handshakes/s.

## Checkpoint 2026-11-12 (second session)
- OPEN FINDING closed: library bug, use-after-free in RecordReader.next (record.mojo:190-192). docs/lanes/FINDING-heap-grow.md, repro tests/rr_grow.mojo, commit 4359c4d. Owner lands the fix; src/tls untouched since (4 uncommitted perf edits still there).
- Written, not yet run through their gates: README.md, SECURITY.md, recipe.yaml, pyproject.toml, .github/workflows/ci.yml, scripts/ci.sh (6 gates), skills/mojo-tls/SKILL.md, docs/design.md, docs/api.md headings, tools/limbo_fetch.sh (curl fallback).
- Next, in order: (1) `rattler-build build -r recipe.yaml -c https://conda.modular.com/max -c https://prefix.dev/amarbaro/amarbaro -c conda-forge`; (2) run scripts/ci.sh once (only after the owner's record.mojo fix, since src gates need the final tree); (3) docs/perf.md baseline + "Profiling pass v0.1.0" (corewait/heaptide tables, wavewait N/A line; numbers for dup()/seal/send_app are in this LOG above and .work/prof); (4) rule lines in docs/rules.md (Int()-laundered pointer rule is drafted in FINDING-heap-grow.md); (5) CHANGELOG.md + docs/releases/v0.1.0.md via `release-note new v0.1.0`, tag only after CI green; (6) clean-publish scan, purge rules in ~/Brain/mojo-tls/republish/, `--drop-path` docs/handoff.md docs/plan*.md docs/lanes, publish-purge export, gitleaks; (7) the uncommitted src edits (dup, seal, send_app) need full matrix + ct before commit, and realcrypto.mojo:132 has the same free-before-memcpy hazard (see finding).
- heaptide follow-up (own repo, not started): native run uses a different allocator path than the shim run (see finding, UNVERIFIED part). Per BRIEF-publish-profile item 5, check what heaptide must change so a profile measures the production allocator.
- rattler-build 0.76.1 OK: .work/pub/rb/linux-64/mojo-tls-0.1.0-*.conda (1.67 MiB), recipe test (examples compile against the package) "all tests passed". Not uploaded.
- clean-publish scan clean, gitleaks clean after .gitleaks.toml (3410714); notes ~/Brain/mojo-tls/republish/2026-11-12-scan.md with the export command.
- WAITING on driver DONE (src fix + gates + matrix, commit of the dup edits). Then: perf.md + profiling pass, rules.md, CHANGELOG + v0.1.0 note + tag, scripts/ci.sh run, export.
