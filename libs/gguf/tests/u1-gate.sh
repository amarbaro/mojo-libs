#!/usr/bin/env bash
# U1 gate: src/gguf_rewrite.mojo parses a GGUF and serializes it again.
#   tests/u1-gate.sh            run from the repo root or any lane worktree; exit 0 only on PASS 16/16
# Fixtures come from the main checkout's .work/oracle (tools/mkoracle.sh), never from the worktree.
# Checks: tests/ tools/ docs/PLAN.md untouched vs main; build; 11 round trips identical-bytes; first stdout
# line `kv K tensors T alignment A data_offset D` equal to gguf-py's values on 2 files (a byte copy cannot
# print it); 2 edits (--name, --remove) identical-bytes to gguf_new_metadata.py output; bf16 wall + RSS line.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
MAIN=$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
ORACLE=$MAIN/.work/oracle/qwen25-05b
FLASH=$HOME/Models/qwen3.8-flash-next/UD-IQ1_M/Qwen3.8-Flash-Next-UD-IQ1_M-00001-of-00003.gguf
PY=$MAIN/.venv/bin/python
W=.work/u1; mkdir -p "$W"
fails=(); n=0
check() { n=$((n + 1)); local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails+=("$name"); fi; }

untouched() { [ -z "$(git diff --name-only main -- tests tools docs/PLAN.md)" ]; }
check gate-files-untouched untouched

build() { "$MAIN/.venv/bin/mojo" build src/gguf_rewrite.mojo -I src -o "$W/gguf-rewrite" > "$W/build.log" 2>&1; }
if ! build; then echo "FAIL build: see $W/build.log"; tail -5 "$W/build.log"; echo "FAIL 1/16 build"; exit 1; fi

rewrite() {
  local src=$1 tag=$2 ref=${3:-$1}; shift 3 || shift $#
  rm -f "$W/out.gguf"
  /usr/bin/time -f "%e s %M KB" -o "$W/$tag.time" "$W/gguf-rewrite" "$src" "$W/out.gguf" "$@" > "$W/$tag.log" 2>&1 || { echo "  rewrite exited non-zero: $W/$tag.log"; return 1; }
  "$PY" -I "$MAIN/tools/gguf-cmp.py" "$ref" "$W/out.gguf" > "$W/$tag.cmp" 2>&1 || true
  grep -q "^PASS identical-bytes" "$W/$tag.cmp" || { head -3 "$W/$tag.cmp" | sed 's/^/  /'; return 1; }
}
summary() {
  local src=$1 tag=$2 want got
  want=$("$PY" -I -c "import sys; sys.path.insert(0, sys.argv[2]); from gguf import GGUFReader; r = GGUFReader(sys.argv[1]); print(f'kv {len(r.fields) - 3} tensors {len(r.tensors)} alignment {r.alignment} data_offset {r.data_offset}')" "$src" "${LLAMACPP:-$HOME/Projects/imports/llama.cpp-master}/gguf-py")
  got=$(head -1 "$W/$tag.log")
  [ "$got" = "$want" ] || { echo "  want '$want' got '$got'"; return 1; }
}
for t in bf16 q8_0-py Q8_0 Q4_0 Q4_K Q6_K Q2_K Q2_0 TQ1_0 TQ2_0; do
  [ -s "$ORACLE/$t.gguf" ] || { echo "FAIL fixture: $ORACLE/$t.gguf missing (tools/mkoracle.sh)"; exit 1; }
  check "rewrite-$t" rewrite "$ORACLE/$t.gguf" "$t"
done
check rewrite-flash-shard1 rewrite "$FLASH" flash
check summary-Q4_K summary "$ORACLE/Q4_K.gguf" Q4_K
check summary-flash summary "$FLASH" flash
for e in Q4_K flash; do
  [ -s "$ORACLE/edit-$e.gguf" ] || { echo "FAIL fixture: $ORACLE/edit-$e.gguf missing (tools/mkoracle.sh)"; exit 1; }
  src=$ORACLE/Q4_K.gguf; [ $e = flash ] && src=$FLASH
  check "edit-$e" rewrite "$src" "edit-$e" "$ORACLE/edit-$e.gguf" --name mojo-gguf-edit --remove tokenizer.chat_template
done
rm -f "$W/out.gguf"
echo "bf16 rewrite: $(cat "$W/bf16.time" 2>/dev/null || echo none) (994 MB file)"
[ ${#fails[@]} -eq 0 ] || { echo "FAIL ${#fails[@]}/$n ${fails[*]}"; exit 1; }
echo "PASS $n/$n"
