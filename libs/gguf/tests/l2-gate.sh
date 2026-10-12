#!/usr/bin/env bash
# L2 gate: `gguf-latent bake IN OUT --wa W.f32 --beta B --row-median M` stores the latent data as KV (latent.version u32
# 1, latent.beta f32, latent.embd_row_median f32, latent.w_a f32 array of d*d, latent.w_a.shape u32 [d, d]): llama.cpp
# rejects unknown TENSORS ("wrong number of tensors", src/llama-model-loader.cpp) but ignores unknown KV, so files stay
# loadable. `gguf-latent show FILE` prints `latent beta B median M w_a DxD`. Fixture: qwen2.5-0.5B W_a from latent-wa.
#   tests/l2-gate.sh    exit 0 only on PASS 7/7 (the load check queues a CPU-only llama-cli under gpu-wait)
source "$(dirname "$0")/gate-lib.sh"
W=$PWD/.work/l2; rm -rf "$W"; mkdir -p "$W"  # per-check logs stay in $W; redirect a gate run elsewhere; LA=$MAIN/.work/oracle/latent
BETA=$(grep -oE '^beta=[0-9.e+-]+' "$LA/qwen-wa.txt" | cut -d= -f2)
MED=$(grep -oE 'median_W_in_row=[0-9.e+-]+' "$LA/qwen-wa.txt" | cut -d= -f2)
check gate-files-untouched untouched
check llama-cpp-pinned pinned
build() { "$MOJO" build src/gguf_latent.mojo -I src -o "$W/gguf-latent" > "$W/build.log" 2>&1; }
check build build
bake() { "$W/gguf-latent" bake "$ORACLE/Q4_K.gguf" "$W/out.gguf" --wa "$LA/qwen-wa.f32" --beta "$BETA" --row-median "$MED" > "$W/bake.log" 2>&1 \
  && "$PY" -I tests/l2-check.py "$GGUFPY" "$ORACLE/Q4_K.gguf" "$W/out.gguf" "$LA/qwen-wa.f32" "$BETA" "$MED" | sed 's/^/     /' | grep -q PASS; }
check bake-readback bake
rebake() { "$W/gguf-latent" bake "$W/out.gguf" "$W/out2.gguf" --wa "$LA/qwen-wa.f32" --beta "$BETA" --row-median "$MED" > /dev/null 2>&1 && cmp -s "$W/out.gguf" "$W/out2.gguf"; }
check rebake-idempotent rebake
show() { local s; s=$("$W/gguf-latent" show "$W/out.gguf"); echo "     $s"; [[ "$s" == "latent beta "*" median "*" w_a 896x896" ]]; }
check show show
load() { [ -s "$W/out.gguf" ] || return 1; local rc=0; gpu-wait run --vram 1 --timeout 600 -- env HIP_VISIBLE_DEVICES=-1 "$LLAMACPP/build/bin/llama-cli" -m "$W/out.gguf" -p "The capital of France is" -n 4 -st -ngl 0 --temp 0 > "$W/load.log" 2>&1 || rc=$?
  [ "$rc" = 0 ] && ! grep -qiE 'error|failed to load' "$W/load.log"; }
check llama-cpp-loads load
finish
