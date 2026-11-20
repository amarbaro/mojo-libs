# Lane brief: mojo-zip v0.1.0 release prep (protocol steps D, N, X)

Model: sonnet, effort high. Repo: $HOME/Projects/mojo/mojo-zip. Report: exchange/lane-release-report.md, then push DONE.

Follow $HOME/Brain/protocols/mojo-library/README.md, steps D, N and X. Reference shape: $HOME/Projects/mojo/mojo-json-public.
Do NOT run G (publish) and do NOT create any remote: the orchestrator does R (review) and G.

Current `mojo-lib-audit mojo-zip` failures to close:
no:docs/api.md, no:skills/mojo-zip/SKILL.md, no:recipe.yaml, badges, badge:license, no:docs/releases/v0.1.0.md,
no-tag:v0.1.0, tracked tools/__pycache__/*.pyc, home paths in CHANGELOG.md and exchange/*.

Known stale facts to fix (numbers only from a gate run you do yourself):
- README says 1224 codec rows and 224 golden rows; the gate prints 2610 codec rows, 11 oracle scenarios x2, and
  tests/golden/vectors.txt holds 230 rows.
- CHANGELOG dates v0.1.0 2026-11-08; the release is 2026-11-10. It links `$HOME/iTools/...` (home path).
- exchange/ (lane briefs and reports) must not reach the -public export.

Steps
1. D: api.md (every public name in src/zipfile/__init__.mojo and src/deflate/__init__.mojo), skill (mojo-json's skill
   shape, every call grepped in src), badges via `repo-badges`, CHANGELOG + `release-note` v0.1.0, untrack the .pyc and
   add `__pycache__/` to .gitignore. Gate: mojo-lib-audit shows none of the D failures.
2. N: `$HOME/Projects/mojo/.work/nightly-check/check.sh mojo-zip` on stable and current nightly; fix what breaks on either.
   Receipt with both toolchain versions in the report.
3. X: clean-publish skill + publish-purge into $HOME/Projects/mojo/mojo-zip-public (squash-export: one commit of the tested
   tip), `recipe-gen`, tag v0.1.0 there. Gate: `mojo-lib-audit mojo-zip-public` prints PASS.

Rules: Mojo 1.2 stable `.venv/bin/mojo`; every command under `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0`;
no timing runs (another lane is building); commit per step, conventional subject + why body, no attribution lines;
never push. Stuck after three repairs on one item: write it in the report and move on.
