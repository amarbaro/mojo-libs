#!/usr/bin/env bash
# L3 gate: `latent-metric REF.gguf TEST.gguf PROMPTS.txt OUT.json` scores how well TEST keeps REF's latent geometry,
# one row per prompt (the last position): cos of the final-norm hiddens (cos_mean, cos_min), argmax agreement of the
# logits (top1_agree), cos of the soft embeddings softmax(logits) . token_embd of each model (soft_cos_mean,
# soft_cos_min), and TEST's W_a known-answer recovery (wa_recovery: share of 256 fixed tokens whose W_out row mapped by
# TEST's W_a lands nearest its own token_embd row, latent-wa's probe). JSON keys: prompts plus those seven, numbers.
# Forward passes may use hidden-probe-dump (llama.cpp CPU); everything after the dump is ours.
#   tests/l3-gate.sh    exit 0 only on PASS 8/8 (qwen2.5-0.5B: bf16 reference, Q4_K and Q2_K oracle quants)
source "$(dirname "$0")/gate-lib.sh"
W=$PWD/.work/l3; rm -rf "$W"; mkdir -p "$W"; P=tests/l3-prompts.txt
check gate-files-untouched untouched
check llama-cpp-pinned pinned
build() { "$MOJO" build src/latent_metric.mojo -I src -o "$W/latent-metric" > "$W/build.log" 2>&1; }
check build build
run() { "$W/latent-metric" "$ORACLE/bf16.gguf" "$ORACLE/$1.gguf" "$P" "$W/$2.json" > "$W/$2.log" 2>&1; }
jget() { "$PY" -I -c 'import json,sys; o=json.load(open(sys.argv[1])); print(o[sys.argv[2]])' "$1" "$2"; }
keys() { run bf16 self && "$PY" -I -c '
import json, sys
o = json.load(open(sys.argv[1]))
need = ["prompts", "cos_mean", "cos_min", "top1_agree", "soft_cos_mean", "soft_cos_min", "wa_recovery"]
sys.exit(0 if all(k in o and isinstance(o[k], (int, float)) for k in need) and o["prompts"] == 32 else 1)' "$W/self.json"; }
check json-keys keys
self_exact() { [ "$(jget "$W/self.json" cos_min)" = 1.0 ] && [ "$(jget "$W/self.json" top1_agree)" = 1.0 ] && [ "$(jget "$W/self.json" soft_cos_min)" = 1.0 ]; }
check self-is-exact self_exact
order() { run Q4_K q4k && run Q2_K q2k && "$PY" -I -c '
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print("     Q4_K", {k: a[k] for k in ("cos_mean", "top1_agree", "soft_cos_mean", "wa_recovery")})
print("     Q2_K", {k: b[k] for k in ("cos_mean", "top1_agree", "soft_cos_mean", "wa_recovery")})
sys.exit(0 if a["cos_mean"] > b["cos_mean"] and a["soft_cos_mean"] > b["soft_cos_mean"] and a["top1_agree"] >= b["top1_agree"] else 1)' "$W/q4k.json" "$W/q2k.json"; }
check q4k-beats-q2k order
repro() { run Q4_K q4k-2 && cmp -s "$W/q4k.json" "$W/q4k-2.json"; }
check reproducible repro
oracle_cos() { hidden-probe-dump "$ORACLE/bf16.gguf" "$P" "$W/dump-ref" > /dev/null 2>&1 && hidden-probe-dump "$ORACLE/Q4_K.gguf" "$P" "$W/dump-q4k" > /dev/null 2>&1 || return 1
  local o; o=$("$PY" -I tests/l3-cos.py "$W/dump-ref" "$W/dump-q4k"); echo "     oracle $o, tool cos_mean $(jget "$W/q4k.json" cos_mean)"
  "$PY" -I -c 'import sys; a=float(sys.argv[1]); b=float(sys.argv[2]); sys.exit(0 if abs(a-b) <= 1e-6 * max(1, abs(a)) else 1)' "$(echo "$o" | cut -d' ' -f2)" "$(jget "$W/q4k.json" cos_mean)"; }
check cos-matches-oracle oracle_cos
finish
