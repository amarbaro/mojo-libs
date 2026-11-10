# Lane report: mojo-zip v0.1.0 release prep (steps D, N, X)

Model sonnet 5.5, effort high. Brief: `exchange/lane-release-brief.md`. No push, no remote, step G not run.

## D: docs and skill (commits 79e0ba4, eb702be)

- `docs/api.md`: every name exported by `src/zipfile/__init__.mojo` and `src/deflate/__init__.mojo`, with raise texts taken from `raise` sites in `src`.
- `skills/mojo-zip/SKILL.md`: 59 lines, mojo-json's shape. Its example block is run by `scripts/docs.sh`, which now covers README and SKILL.md.
- Badges via `repo-badges` with `REPO_BADGES_SLUG=amarbaro/mojo-zip` (no origin exists, none was added). `.github/workflows/ci.yml` now calls the shared `lib-ci` workflow as in mojo-json; `scripts/ci.sh` prints `PASS n/m` and honours `MOJO=`.
- CHANGELOG dated 2026-11-10 with no home path; `docs/releases/v0.1.0.md` by hand (the `release-note new` scaffold duplicated the CHANGELOG line and pulled the README into "What it does").
- `tools/__pycache__/*.pyc` untracked, `__pycache__/` and `*.pyc` ignored.
- README numbers from this run's gate: 2610 codec rows, 11 oracle scenarios (each twice), 230 golden rows (231 lines, one header). Negative control rejects 600 of 2610. Gate: `.work/release-gate.txt`, exit 0.
- `exchange/*` paths rewritten to `$HOME/`, including the dispatcher's brief (path notation only).
- `recipe.yaml` by `recipe-gen`; `pyproject` packages reordered to `["deflate", "zipfile"]`. Checked: `zipfile.mojoc` alone fails with `unable to locate module 'deflate'`, so both `.mojoc` files ship.

## N: toolchain matrix (commit 150998e)

| Toolchain | Result |
|---|---|
| Mojo 1.2.0 (2016d0cd) | `scripts/ci.sh` `PASS 5/5`, `PASS ci` (log `.work/ci-stable.txt`) |
| Mojo 1.3.0.dev2026110805 (11efb73e) | first `nightly-check/check.sh mojo-zip`: FAIL pkg:zipfile, run:quickstart; after the fix `ok`; `MOJO=<nightly> scripts/ci.sh` `PASS 5/5` incl. 27 of 27 mutants (log `.work/ci-nightly.txt`) |

Break: `FileHandle` is not implicitly copyable on the nightly, so `var f = open(...); f.close()` in `src/zipfile/writer.mojo` (two sites) did not compile. Fix: `with open(...)`. Builds on both. No API change, so no `nightly-*-changes.md` entry.

## X: export

- Scan: `$HOME/Brain/mojo-zip/republish/scan-2026-11-10.md`. Authors only `amarbaro.org <dev@amarbaro.org>`; tip tree outside `exchange/` has no home path, name, host or secret.
- `publish-purge ... --drop-path exchange --keep-branch main`: `PASS -- all verifications clean`, gitleaks clean (log `.work/purge.txt`). It rewrote nothing else (no replace rules needed).
- Squash: `$HOME/Projects/mojo/mojo-zip-public` holds one commit (5d9f694) of the tested tip 150998e minus `exchange/`; `v0.1.0` annotated tag on it; no remote; reflog expired and gc'd.
- `recipe-gen` on the export equals the committed `recipe.yaml`.
- In the export: `scripts/docs.sh` `PASS docs`, `examples/quickstart.mojo` ran (`ok 1240 bytes from 72 compressed`).
- Gate: `mojo-lib-audit $HOME/Projects/mojo/mojo-zip-public` prints `mojo-zip PASS`.
- Source repo also carries local tag `v0.1.0` at 150998e (closes `no-tag`).

## For the orchestrator (R and G)

- README install line (`pixi add mojo-zip`) is true only after G and the conda upload.
- The 35,000-archive fuzz row in the release note is from the earlier lane run (`tools/fuzz.py`, before the writer change); the writer change touches only file creation and appending, not the archive bytes, and `ci.sh` api and oracle gates passed after it.
- Open owner decision carried over: `ZipInfo` is 340 B per entry against the 200 B plan target (changes the public struct).
- No timing runs were made.
