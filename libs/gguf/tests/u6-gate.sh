#!/usr/bin/env bash
# U6 gate (CPU): `gguf-dequant MODEL TENSOR ROW0 N OUT.f32` bit-equal to the pinned llama.cpp to_float on every tensor
# type of the five ladder models (docs/PLAN.md U6), driver tests/u6-check.py.
#   tests/u6-gate.sh [FILE.gguf...]    exit 0 only on PASS; default: the five models' files
source "$(dirname "$0")/gate-lib.sh"
W=$PWD/.work/u6; rm -rf "$W"; mkdir -p "$W"
M=$HOME/Models
FILES=("$@"); [ ${#FILES[@]} -gt 0 ] || FILES=(
  "$M"/qwen3.8-flash-next-gsq/Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-0000{1,2}-of-00002.gguf
  "$M"/qwen3.8-flash-next/UD-IQ1_M/Qwen3.8-Flash-Next-UD-IQ1_M-0000{1,2,3}-of-00003.gguf
  "$M"/RegesCore-1.0-35/RegesCore-1.0-35B-UD-Q4_K_S-BARO-e40d9ca.gguf
  "$M"/RegesCore-1.0-35/.work/lowbit/RegesCore-35B-TQ1_0.gguf
  "$M"/qwen3.8-27b-obliterated-q4_K_M/Qwen3.8-27B-OBLITERATED.Q4_K_M.gguf
  "$M"/qwythos-9b-v2-mtp-q6_k/Qwythos-9B-v2-MTP-Q4_0-BARO-04867e2.gguf)
check gate-files-untouched untouched
check llama-cpp-pinned pinned
build() { "$MOJO" build src/gguf_dequant.mojo -I src -o "$W/gguf-dequant" > "$W/build.log" 2>&1; }
check build build
rows() { "$PY" -I tests/u6-check.py "$GGUFPY" "$LLAMACPP/build/bin/libggml-base.so" "$W/gguf-dequant" "$W" "${FILES[@]}" 2>&1 | tee "$W/check.log" | sed 's/^/     /'; grep -q '^PASS' "$W/check.log"; }
check rows-bit-equal rows
finish
