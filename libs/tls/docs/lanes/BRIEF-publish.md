# Brief: make mojo-tls publish-ready like mojo-zstd (sonnet lane tls-pub)

Repo `~/Projects/mojo/mojo-tls` (branch master, head c2216c7, no remote: never add one). Model repos: `~/Projects/mojo/mojo-zstd` and `~/Projects/mojo/mojo-msgpack` (published). Match their layout and quality.
Read first: `docs/rules.md`, `docs/api.md`, `docs/handoff.md`, skills `~/Brain/Skills/own/clean-publish/SKILL.md` (follow it, all of it) and `mojo-lean`; prefix.dev notes via `brain-ask "pixi upload prefix channel recipe"`.

## Deliverables
1. **README.md** complete: what it is (pure-Mojo TLS 1.3 + 1.2, x509, which ciphers, groups and features: resumption, client certs, P-384, x448), what it is not (the 11 matrix SKIPs as policy), install (pixi / prefix.dev channel, same wording as mojo-zstd), quickstart client + server (code that compiles: put it in `examples/` and test it), test evidence with numbers (full matrix 176 PASS / 11 SKIP / 0 FAIL, Wycheproof counts, tlsfuzzer, interop with openssl/Firefox/Chromium), perf table if a bench exists, security note (constant-time checks, how to report issues), license.
2. **LICENSE** (Apache-2.0, as siblings) + **NOTICE**; third-party test vectors (Wycheproof, tlsfuzzer data, RFC vectors) credited with their licenses.
3. **recipe.yaml + pyproject.toml** like mojo-zstd (package `mojo-tls`, version 0.1.0 unless docs say otherwise), `rattler-build build` passes locally; do NOT upload.
4. **skills/mojo-tls/SKILL.md**: the shipped skill, when to use, API in 20 lines, gotchas.
5. **docs/**: public docs stay (api, design = merge of sym/asym/tls12/tls13/x509 overviews or keep them linked, perf, releases/v0.1.0.md); internal files (handoff.md, plan*.md, lanes/, rules.md) are excluded from the export the way siblings do it (check how mojo-zstd keeps rules.md/exchange out, or not).
6. **CHANGELOG.md**, release note via `release-note`, tag `v0.1.0` (local tag only).
7. **CI** `.github/workflows/ci.yml` like mojo-zstd: build + the fast gates (no lab, no network matrix).
8. **Size**: repo is 822 MB. Find what (`du`, `publish-purge`), keep large test data out of the export (fetched by a script or kept small), committed build outputs removed from history in the export.
9. **clean-publish scan + export**: home paths, real names/emails, lab host names/IPs, secrets (gitleaks), one branch. Produce the export dir the skill describes and say its path and size.

## Checks
- Every gate still exits 0 after the changes (run only the gates the change can affect; full matrix only if src/ changed).
- Example code compiles and runs.
- `rattler-build build` OK.
- Export: gitleaks clean, scan clean, size printed.

## Rules
Commit as work lands, conventional subject + why body, no co-author line. Never push, never add a remote: the owner pushes.
Log: `docs/lanes/LOG-publish.md`.
Done: `herd tell wXG:p3 'DONE tls-pub -> docs/lanes/LOG-publish.md (export <path> <size>)'`. Stuck: `herd tell wXG:p3 'QUESTION tls-pub: ...'`.
