#!/usr/bin/env bash
# MEMIT gate (bench/MEMIT_PREREG.md): the baked adapter goes through lora2gguf -> llama-export-lora -> llama-quantize,
# and stock llama.cpp scores recall on bf16 and Q4_K_M against the same-type base. The R = 0 mutant must fail.
#   tests/memit-gate.sh [ADAPTER_DIR]    (default .work/memit/adapter, made by tools/memit_oracle.py bake)
#   exit 0 only on PASS n/n; receipt in .work/memit/receipt.txt
source "$(dirname "$0")/gate-lib.sh"
W=$MAIN/.work/memit; AD=${1:-$W/adapter}; BIN=${LLAMA_BIN:-$HOME/Models/llama.cpp/build/bin}
BASE=$MODELS/qwen2.5-0.5b-instruct-import/qwen2.5-0.5b-instruct-bf16.gguf
FACTS=$W/facts.jsonl; PYS=$MAIN/tools/memit_check.py; R=$W/receipt.txt; : > "$R"
held() { local n; n=$(wc -c < "$ORACLE/../l1-ppl.txt"); tail -c $((n / 2)) "$ORACLE/../l1-ppl.txt" > "$W/heldout.txt"; }
held  # covariance used the first 20k tokens; perplexity uses the second half of the file
"$MOJO" build src/lora2gguf.mojo -I src -o "$W/lora2gguf" > "$W/build.log" 2>&1 || { echo "FAIL build lora2gguf"; exit 1; }

variant() {  # name adapter_dir: adapter gguf -> merged bf16 -> merged q4
  "$W/lora2gguf" "$2" --base "$HF05" --outfile "$W/$1-lora.gguf" --outtype f32 > "$W/$1-conv.log" 2>&1 &&
  "$BIN/llama-export-lora" -m "$BASE" --lora "$W/$1-lora.gguf" -o "$W/$1-bf16.gguf" > "$W/$1-merge.log" 2>&1 &&
  "$BIN/llama-quantize" "$W/$1-bf16.gguf" "$W/$1-q4.gguf" Q4_K_M > "$W/$1-q4.log" 2>&1
}
ppl() { "$BIN/llama-perplexity" -m "$1" -f "$W/heldout.txt" -c 512 -ngl 99 2>&1 | sed -n 's/.*Final estimate: PPL = \([0-9.]*\).*/\1/p'; }
score() {  # model -> {"edit":..}
  "$BIN/llama-server" -m "$1" -ngl 99 --port 18431 -np 16 -c 8192 > "$W/server.log" 2>&1 & local pid=$!
  for _ in $(seq 120); do curl -sf localhost:18431/health > /dev/null && break; sleep 0.5; done
  "$PY" -I "$PYS" score http://localhost:18431 "$FACTS"; kill $pid; wait $pid 2>/dev/null || true
}
cp "$BASE" "$W/base-bf16.gguf"; "$BIN/llama-quantize" "$W/base-bf16.gguf" "$W/base-q4.gguf" Q4_K_M > "$W/base-q4.log" 2>&1
check convert-merge-quantize variant edit "$AD"
"$PY" -I "$PYS" zero "$AD" "$W/adapter-zero" && variant zero "$W/adapter-zero"

band() {  # expr: python boolean over e (edited scores), b (base scores), p, q (edited, base perplexity)
  "$PY" -I -c "import json,sys; e=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); p,q=float(sys.argv[3]),float(sys.argv[4]); sys.exit(0 if ($1) else 1)" "$e" "$b" "$pe" "$pb"
}
for t in bf16 q4; do
  e=$(score "$W/edit-$t.gguf"); b=$(score "$W/base-$t.gguf"); z=$(score "$W/zero-$t.gguf")
  pe=$(ppl "$W/edit-$t.gguf"); pb=$(ppl "$W/base-$t.gguf")
  echo "$t edit=$e base=$b zero=$z ppl_edit=$pe ppl_base=$pb" | tee -a "$R"
  [ $t = bf16 ] && lo=(0.90 0.60 0.02) || lo=(0.80 0.50 0.03)
  check "$t-edit-recall" band "e['edit'] >= ${lo[0]}"
  check "$t-paraphrase" band "e['para'] >= ${lo[1]}"
  check "$t-neighbours" band "b['neigh'] - e['neigh'] <= ${lo[2]}"
  check "$t-perplexity" band "p <= q * 1.02"
  e=$z; check "$t-mutant-fails" band "e['edit'] <= 0.05"
done
sha256sum "$W"/edit-*.gguf "$W"/base-*.gguf >> "$R"
finish
