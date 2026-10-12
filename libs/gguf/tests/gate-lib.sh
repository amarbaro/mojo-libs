# Shared by tests/u*-gate.sh (source it). Gates run from the repo root or any lane worktree; fixtures come from the
# main checkout's .work/oracle, the oracle library from the pinned llama.cpp checkout, never from the worktree.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
MAIN=$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
ORACLE=$MAIN/.work/oracle/qwen25-05b
LLAMACPP=${LLAMACPP:-$HOME/Projects/imports/llama.cpp-master}
GGUFPY=$LLAMACPP/gguf-py
PY=$MAIN/.venv/bin/python
MOJO=$MAIN/.venv/bin/mojo
HF05=$HOME/Models/qwen2.5-0.5b-instruct-hf
fails=(); n=0
check() { n=$((n + 1)); local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails+=("$name"); fi; }
# gate files are frozen: a lane may add files, never modify or delete what its branch point had
untouched() { [ -z "$(git diff --name-only --diff-filter=MDR "$(git merge-base HEAD main)" -- tests tools/oracle.sh tools/mkoracle.sh tools/gguf-cmp.py docs/PLAN.md)" ]; }
pinned() { [ "$(git -C "$LLAMACPP" rev-parse --short=9 HEAD)" = 1744c6bde ]; }
finish() { if [ ${#fails[@]} -gt 0 ]; then echo "FAIL ${#fails[@]}/$n ${fails[*]}"; exit 1; fi; echo "PASS $n/$n"; }
