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

## Adding a library

```
git clone --no-local <repo> tmp && git -C tmp filter-repo --to-subdirectory-filter libs/<name>
git fetch tmp <branch> && git merge --allow-unrelated-histories FETCH_HEAD
```

Then replace any `../mojo-<x>` or clone of a sibling by `../<x>`, add the row to `libs.txt`, run `scripts/deps-scan.sh --write`
and `scripts/check.sh --write`, and check `scripts/ci-all.sh <name>`.
