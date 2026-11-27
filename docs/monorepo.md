# One repository, one folder per library

Every library lives in `libs/<name>/` and keeps its own package, import name, version, `recipe.yaml`, `pixi.toml`,
`shelf.toml`, oracle suite and `CHANGELOG.md`. Nothing is shared between folders except what a library names as a sibling.

## Siblings

A library reaches another as `../<name>`: `-I ../json/src` in a build line, `../proptest/src` for the property tests,
`lib/<pkg>` symlinks made by `scripts/deps.sh` (bento, gguf). No script clones one of our libraries from GitHub.
`deps.tsv` lists who uses whom; `scripts/deps-scan.sh --check` fails when it is stale, `--write` rebuilds it. CI uses it
to run the dependents of a changed library.

`prometheus`, `subprocess` and `tokenizers` carry no vendored copy of `pyformat`, `posix`, `json` or `uregex`; their
`pixi.toml` points at the sibling folder by path and their build scripts add `-I ../<name>/src`.

## Releases

A tag `<name>-v<version>` (`json-v0.1.4`, `gguf-core-v0.1.5`) runs `.github/workflows/conda.yml`: it checks the version in
`libs/<name>/recipe.yaml`, builds that recipe and uploads it to prefix.dev. Locally the same build is
`pixi exec rattler-build build -r libs/<name>/recipe.yaml -c https://prefix.dev/amarbaro/amarbaro -c https://conda.modular.com/max -c conda-forge`.
`struct` has no `recipe.yaml` yet, so it has no conda tag.

### Ship workflow (every release, every library)

`lib-ship status [LIB...]` (iTools) prints one row per library for the three channels and writes `.work/ship-status.md`.
Its NEXT column names the steps still open, always in this order:

```
1 push      libs/<name> differs from origin/main: clean branch off origin/main, cherry-pick, lib CI, push main
2 bump      main changed since the published version: raise recipe.yaml, shelf.toml, CHANGELOG.md
3 tag       release-note new vX.Y.Z on the clean branch, release-note tag -> <name>-vX.Y.Z
4 push-tag  git push origin <name>-vX.Y.Z; conda.yml builds and uploads to prefix.dev
5 prefix    the tag version is not on prefix.dev amarbaro/amarbaro: read the conda.yml run, fix, retag
6 shelf     shelf.toml version is not on mojoshelf: `shelf publish` in libs/<name>
```

A release is done when the library's row reads `ok`. Run it before a release and after the last step.

## Adding a library

```
git clone --no-local <repo> tmp && git -C tmp filter-repo --to-subdirectory-filter libs/<name>
git fetch tmp <branch> && git merge --allow-unrelated-histories FETCH_HEAD
```

Then replace any `../mojo-<x>` or clone of a sibling by `../<x>`, add the row to `libs.txt`, run `scripts/deps-scan.sh --write`
and `scripts/check.sh --write`, and check `scripts/ci-all.sh <name>`.
