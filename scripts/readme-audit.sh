#!/usr/bin/env bash
# README contract of every library in the index (mojo-library protocol, step D):
# badges, prefix.dev install line, toolchain line with the mojo-libs link, a limits statement,
# a table of calls, links to docs/, and a first ```mojo block that runs as written.
# usage: scripts/readme-audit.sh [--no-run]   (LIBS_DIR: parent of the library checkouts)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
LIBS_DIR=${LIBS_DIR:-$(dirname "$here")}
run=y; [ "${1:-}" = --no-run ] && run=n
# blocks that need a built binary, a model file, a GPU, or fail on purpose (protocol N: harness cases)
harness=" mojo-bento mojo-posix mojo-gguf mojo-proptest mojo-vattn "  # vattn: GPU, run through gpu-wait by hand
mojo=${MOJO:-}
fails=0; n=0
for repo in $(grep -oE 'github.com/amarbaro/[A-Za-z0-9_-]+\)' "$here/README.md" | sed 's|.*/||; s|)||' | sort -u); do
  [ "$repo" = mojo-libs ] && continue
  # a library can have a dev and a -public checkout: take the one whose HEAD contains GitHub main
  d=""; for c in "$LIBS_DIR/$repo-public" "$LIBS_DIR/$repo"; do
    [ -f "$c/README.md" ] || continue; [ -z "$d" ] && d=$c
    git -C "$c" merge-base --is-ancestor origin/main HEAD 2>/dev/null && { d=$c; break; }
  done
  [ -n "$d" ] || { echo "FAIL $repo: no checkout under $LIBS_DIR"; fails=$((fails+1)); continue; }
  f=$d/README.md; n=$((n+1)); miss=()
  grep -q 'actions/workflows/.*badge.svg' "$f" || miss+=(ci-badge)
  grep -q 'shields.io/github/license' "$f" || miss+=(license-badge)
  grep -q '^Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`' "$f" || miss+=(install)
  grep -qE '^Toolchains?: .*\[mojo-libs\]\(https://github.com/amarbaro/mojo-libs\)' "$f" || miss+=(toolchain)
  grep -qiE '^## .*(limit|not covered)|^\*\*(limits|requires|known limits)|^not supported:' "$f" || miss+=(limits)
  grep -qE '^\|.*\|$' "$f" || miss+=(table)
  grep -q '](docs/' "$f" || miss+=(docs-links)
  grep -qiE 'once published|1\.2 nightly' "$f" && miss+=(stale-text)
  if [ $run = y ] && [[ $harness != *" $repo "* ]]; then
    m=$d/.venv/bin/mojo; [ -x "$m" ] || m=$mojo
    inc=(-I "$d/src")  # sibling libraries named in the recipe
    for dep in $(grep -oE '^ +- mojo-[a-z0-9-]+' "$d/recipe.yaml" 2>/dev/null | sed 's/^ *- //' | grep -v compiler | sort -u); do
      for c in "$LIBS_DIR/$dep-public" "$LIBS_DIR/$dep"; do [ -d "$c/src" ] && { inc+=(-I "$c/src"); break; }; done
    done
    if [ -x "$m" ]; then  # runs in the repo: some examples read tests/fixtures
      t=$(mktemp -d); awk '/^```mojo/{f=1;next} /^```/{if(f){exit}} f' "$f" > "$t/readme.mojo"
      if [ ! -s "$t/readme.mojo" ]; then miss+=(no-example)
      elif ! (cd "$d" && timeout 180 "$m" run "${inc[@]}" "$t/readme.mojo" > "$t/out" 2>&1); then miss+=("example: $(grep -m1 -iE 'error|exception' "$t/out" | cut -c1-80)"); fi
      rm -rf "$t"
    else miss+=("example: no mojo at $m (set MOJO=)"); fi
  fi
  if [ ${#miss[@]} -gt 0 ]; then echo "FAIL $repo: ${miss[*]}"; fails=$((fails+1)); fi
done
[ $n -gt 0 ] || { echo "FAIL setup: no library found in README.md"; exit 1; }
[ $fails = 0 ] && echo "PASS readme: $n libraries" || { echo "FAIL readme: $fails of $n"; exit 1; }
