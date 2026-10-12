#!/usr/bin/env bash
# L1 gate = the bars of docs/prereg/l1-latent-precision.md (frozen). Parity of per-tensor overrides vs pinned
# llama-quantize, then the committed recipe against llama.cpp Q4_K_M on held-out latent metric and perplexity.
#   tests/l1-gate.sh    exit 0 only on PASS 10/10 (perplexity runs CPU-only under gpu-wait)
source "$(dirname "$0")/gate-lib.sh"
W=$PWD/.work/l1; rm -rf "$W"; mkdir -p "$W"; OR=$MAIN/.work/oracle
HELD=$OR/l1-heldout-prompts.txt; PPLT=$OR/l1-ppl.txt; REF=$ORACLE/Q4_K_M.gguf; BUDGET=397807584
check gate-files-untouched untouched
check llama-cpp-pinned pinned
check fixtures-pinned bash -c "[ \$(sha256sum '$HELD' | cut -c1-16) = 944301bedb25d6f2 ] && [ \$(sha256sum '$PPLT' | cut -c1-16) = 4315bf6d79ff4610 ] && [ \$(stat -c %s '$REF') = $BUDGET ]"
build() { "$MOJO" build src/quantize.mojo -I src -o "$W/quantize" > "$W/build.log" 2>&1 && "$MOJO" build src/latent_metric.mojo -I src -o "$W/latent-metric" >> "$W/build.log" 2>&1; }
check build build
par() { local tag=$1; shift
  "$LLAMACPP/build/bin/llama-quantize" --pure "$@" "$ORACLE/bf16.gguf" "$W/$tag-ref.gguf" Q4_K > "$W/$tag-ref.log" 2>&1 || return 1
  "$W/quantize" --pure "$@" "$ORACLE/bf16.gguf" "$W/$tag.gguf" Q4_K > "$W/$tag.log" 2>&1 || return 1
  "$PY" -I tools/gguf-cmp.py "$W/$tag-ref.gguf" "$W/$tag.gguf" > "$W/$tag.cmp" 2>&1; grep -q '^PASS identical-bytes' "$W/$tag.cmp" || { sed 's/^/     /' "$W/$tag.cmp" | head -5; return 1; }; }
check parity-token-embd par te --token-embedding-type q8_0
check parity-output par out --output-tensor-type q6_k
check parity-tensor-type par tt --tensor-type ffn_down=q6_k
mk() { [ -s recipes/qwen25-05b.txt ] || return 1
  local args=(); while IFS= read -r l; do [ -n "$l" ] && [ "${l:0:1}" != "#" ] && args+=($l); done < recipes/qwen25-05b.txt
  "$W/quantize" --pure "${args[@]}" "$ORACLE/bf16.gguf" "$W/l1.gguf" Q4_K > "$W/l1.log" 2>&1 || return 1
  local b; b=$(stat -c %s "$W/l1.gguf"); echo "     L1 bytes $b (budget $BUDGET)"; [ "$b" -le "$BUDGET" ]; }
check bytes-within-budget mk
lat() { [ -s "$W/l1.gguf" ] || return 1
  "$W/latent-metric" "$ORACLE/bf16.gguf" "$REF" "$HELD" "$W/ref.json" > "$W/ref-m.log" 2>&1 && "$W/latent-metric" "$ORACLE/bf16.gguf" "$W/l1.gguf" "$HELD" "$W/l1.json" > "$W/l1-m.log" 2>&1 || return 1
  "$PY" -I -c '
import json, sys
r, l = (json.load(open(p)) for p in sys.argv[1:3])
for n, o in (("Q4_K_M", r), ("L1", l)): print("     %-6s" % n, {k: round(o[k], 6) for k in ("soft_cos_mean", "cos_mean", "top1_agree", "wa_recovery")})
sys.exit(0 if l["soft_cos_mean"] > r["soft_cos_mean"] and l["cos_mean"] >= r["cos_mean"] else 1)' "$W/ref.json" "$W/l1.json"; }
check heldout-latent-better lat
ppl() { local f=$1 o=$2; gpu-wait run --vram 1 --timeout 1800 -- env HIP_VISIBLE_DEVICES=-1 "$LLAMACPP/build/bin/llama-perplexity" -m "$f" -f "$PPLT" -c 512 -ngl 0 > "$o" 2>&1; grep -oE 'Final estimate: PPL = [0-9.]+' "$o" | grep -oE '[0-9.]+$'; }
pp() { [ -s "$W/l1.gguf" ] || return 1; local a b; a=$(ppl "$REF" "$W/ppl-ref.log"); b=$(ppl "$W/l1.gguf" "$W/ppl-l1.log"); echo "     ppl Q4_K_M $a  L1 $b"
  [ -n "$a" ] && [ -n "$b" ] && "$PY" -I -c 'import sys; sys.exit(0 if float(sys.argv[2]) <= float(sys.argv[1]) else 1)' "$a" "$b"; }
check perplexity-not-worse pp
finish
