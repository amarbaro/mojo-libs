# CI for the libraries: one shared workflow, one weekly matrix

Every library calls one reusable workflow, and one Monday run builds all 36 on stable and nightly Mojo.

## Parts

```
library repo                         mojo-libs
.github/workflows/ci.yml  --uses-->  .github/workflows/lib-ci.yml   (push + PR gate, badge)
(caller, templates/ci.yml)

                                     .github/workflows/matrix.yml   (Mondays + dispatch)
                                       plan -> cell (lib x stable|nightly) -> report
                                       report: status.md + shields -> orphan `status` branch
                                               one issue per failure group
```

| file | job |
|---|---|
| `.github/workflows/lib-ci.yml` | reusable gate: checkout, setup-uv, `scripts/ci.sh` teed to `ci.log` (bash = pipefail), `checks` badge on main pushes. Inputs: `mojo` (stable\|nightly), `apt`, `pre` |
| `templates/ci.yml` | the caller; `ci-setup.tsv` adds `apt`/`pre` for the two libraries that need them |
| `scripts/ci-adopt.sh LIB DIR` | writes one caller; `ci-adopt-all.sh` commits it on a local branch `shared-ci` in every checkout (temporary worktree, the checkout keeps its branch) |
| `scripts/ci-local-shared.sh LIB` | `ci-local` cannot follow `uses:`, so this resolves the caller's `with:` into lib-ci's job in a scratch clone, then runs `ci-local` |
| `.github/workflows/matrix.yml` | weekly matrix; cell logic is `scripts/matrix-cell.sh` |
| `scripts/matrix-local.sh LIB...` | the same cells on this machine, both channels |
| `scripts/matrix-report.sh` | `status.md` + `shields/LIB.json` (shields.io endpoint) |
| `scripts/matrix-issues.sh` | groups failed cells by first `error:` line, one issue per group |
| `scripts/error-line.sh LOG [--key]` | the first error line; `--key` strips paths, line:col, addresses |
| `scripts/test-ci.sh` | the tests (no network, no Mojo) |

`LIBS_DIR` points the scripts at the library checkouts (default: the parent of this repo; a worktree lane sets it).

## Choices that are easy to get wrong

- **Nightly = `MOJO=`.** The only mechanism that exists: `scripts/ci.sh` reads `MOJO` and uses it for every mojo call, in `ci.sh`
  and in the scripts it calls (`${MOJO:-.venv/bin/mojo}`; unset, the commands are the same as before). 35 of 36 libraries do. With
  `MOJO` set, a library whose oracle is the system `python3` skips `uv sync` (it only installs Mojo); one whose oracle lives in `.venv`
  (bento, cv, gguf, gguf-core, msgpack, proptest, safetensors, tokenizers, uregex, zstd) still syncs and ignores the `.venv` Mojo.
  **xmojo cannot switch**: its gate is `pixi run gate` and pixi puts its own `mojo==1.2.0` first on `PATH`, so its nightly cell is `na`.
  Not covered: `bench.sh`, `mutants.sh` (imkit), `local_gate.sh`, `gpu-gates.sh` keep `.venv/bin/mojo`; `ci.sh` does not call them.
  A local `scripts/matrix-local.sh` run needs a short `OUT=` (27 characters or fewer, e.g. `OUT=$HOME/.nmx`): posix, systemd and subprocess bind
  Unix sockets under the clone, and a socket path holds 107 bytes.
  The cell installs `mojo max` from `whl.modular.com/nightly/simple/` into a separate venv
  (same date for both, m.ledger/tooling 2026-10-21). `lib-ci.yml` and `matrix-cell.sh` carry the same install line; a test keeps them equal.
- **Remote name = checkout name minus `-public`** (`mojo-json-public` -> `amarbaro/mojo-json`). libs.txt names checkouts.
- **A caller needs `permissions: contents: write`** or the badge push is refused (a reusable workflow's token is capped by the caller).
- **Job name changes.** The 36 old jobs were `check`, `gate`, `conformance`; the status context becomes `ci / ci`. A branch protection that
  requires the old name must be updated at rollout (not checked: this lane makes no GitHub reads of repo settings).
- **xmojo keeps its own workflow**: pixi, a daily `pixi update` schedule and a 30 min timeout are not `lib-ci` inputs.
  The matrix still runs it (`pixi update` is its row in `ci-setup.tsv`, `setup-pixi` is a step of every cell).
- Issue marker: `<!-- matrix-group:HASH -->` (HASH = first 12 hex of sha1 of the stripped error line). Titles are for people, never matched.

## Requirements

Callers pin `lib-ci.yml@v1`. The matrix needs Actions enabled on this repo; a private library would need a token that can clone it (`GITHUB_TOKEN` reads only mojo-libs and public repos).
