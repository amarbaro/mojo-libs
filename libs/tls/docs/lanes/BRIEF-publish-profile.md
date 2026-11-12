# Brief addendum for tls-pub: profiling pass (standard before every publish)

User decision 2026-11-12, now a standard rule in `~/Brain/protocols/mojo-library/README.md` (section T).
Do this before the export step of BRIEF-publish.md.

1. **memory-optimization**: load skill `~/Brain/Skills/own/memory-optimization/SKILL.md` (+ `references/mojo.md`). Name the hot paths (record encrypt/decrypt AES-GCM and ChaCha20-Poly1305, handshake: ECDHE x25519/P-256/P-384, signature verify, x509 chain parse, record framing), measure bytes and seconds before and after, fix what it finds.
2. **corewait** (`~/Projects/mojo/corewait`, read its README and skill): CPU stall profile of the bench binaries (`tests/bench*.mojo`). Per hot path: top stalled instructions and cause; fix the cheap ones.
3. **heaptide** (`~/Projects/tools/heaptide`, README + skill): heap profile of a full handshake + 1 MB transfer, client and server; allocations per handshake, peak, leaks.
4. **wavewait** (`~/Projects/mojo/wavewait`): it profiles gfx1100 GPU kernels. If mojo-tls has no GPU code, record "wavewait: N/A, no GPU kernels" in `docs/perf.md`. Do not invent a GPU path.
5. A tool that cannot measure mojo-tls (e.g. Mojo binary symbols, threading) is **extended to fit** in its own repo, own commit, own test, not skipped. Say what you changed.
6. Every optimization measured against the previous binary: keep `bench-before`, alternate pinned to one core (`taskset -c N`), several rounds, medians, peak RSS `/usr/bin/time -f %M`. Worse = revert, record the attempt.
7. Constant-time code stays constant-time: rerun `tests/ct.mojo` and the timing gate after any change in crypto code. Full matrix if `src/` changed.
8. Output: `docs/perf.md` section "Profiling pass v0.1.0" (tables per tool, before/after), commit bodies carry `hot path: X · before A / after B` and `loc: before N · after M`. Add the rule line to `docs/rules.md` too.
