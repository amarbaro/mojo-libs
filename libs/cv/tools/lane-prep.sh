#!/usr/bin/env bash
# lane-prep.sh WORKTREE ITEM REPO: link the gitignored toolchain and make .work in a fresh lane worktree
set -euo pipefail
ln -sfn "$(readlink -f "$3/.venv")" "$1/.venv"
mkdir -p "$1/.work" "$1/exchange"
