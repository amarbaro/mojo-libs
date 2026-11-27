#!/usr/bin/env bash
# SigLIP text ids gate: the 64 ids mcv-labels makes for 2000 seeded ASCII texts (mixed case, punctuation, digits, runs of
# blanks, tabs, over-long ones) equal transformers' SiglipTokenizer(padding="max_length", max_length=64, truncation=True).
# The reference is the slow SentencePiece tokenizer of google/siglip-base-patch16-224 (Apache-2.0); the Mojo side is
# mojo-tokenizers' Unigram on the same tokenizer.json cut down to what it supports: Precompiled charsmap + the double-space Replace
# (lower case, punctuation and blank folding are `canon` in src/siglabel.mojo; byte_fallback off, so text outside ASCII is out of scope).
# Planted: texts with one letter changed must differ from the reference ids.
# Usage: SIGLIP_TOK=<dir with spiece.model + tokenizer.json> tests/siglip_tok.sh   (SIGLIP_TOK is required, no default)
set -euo pipefail
cd "$(dirname "$0")/.."
W=.work/siglip; mkdir -p $W .bin
TOK=${SIGLIP_TOK:?set SIGLIP_TOK to the SigLIP tokenizer dir (spiece.model + tokenizer.json)};P=${MOJO_PROJECTS:-$HOME/Projects/mojo}
for f in spiece.model tokenizer.json; do [ -f "$TOK/$f" ] || { echo "FAIL input: $TOK/$f missing"; exit 1; }; done
jq -c '.normalizer.normalizers = [.normalizer.normalizers[4], .normalizer.normalizers[5]] | .model.byte_fallback = false' "$TOK/tokenizer.json" > $W/tokenizer_pre.json
scripts/build-labels.sh || exit 1
uv run -q --no-project --with transformers --with sentencepiece --with protobuf python -I - "$TOK" $W <<'EOF' 2>/dev/null || { echo "FAIL oracle: transformers SiglipTokenizer"; exit 1; }
import random, sys
from transformers import SiglipTokenizer
tok, w = sys.argv[1], sys.argv[2]
t = SiglipTokenizer.from_pretrained(tok)
words = [p.replace("▁", "") for p in t.get_vocab() if p.isascii() and "<" not in p]  # a literal <unk> or </s> in a text is a special token to the reference; labels never hold one
words = [x for x in words if x] + ["a", "photo", "of", "the", "cat", "3d", "icon", "UI", "stock", "x", "AI"]
punct = list("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
rnd = random.Random(2026)
texts = ["a photo of a cat.", "A PHOTO OF A CAT", "icons-ui", "health & wellness", "  leading and trailing  ", "tab\tsplit\nnewline", "x" * 200, "word " * 80]
while len(texts) < 2000:
    n = rnd.choice([1, 2, 3, 5, 8, 14, 40, 90])
    parts = []
    for _ in range(n):
        x = rnd.choice(words)
        if rnd.random() < 0.3: x = x.upper() if rnd.random() < 0.5 else x.capitalize()
        if rnd.random() < 0.2: x += rnd.choice(punct)
        if rnd.random() < 0.05: x = str(rnd.randrange(10 ** rnd.randrange(1, 6)))
        parts.append(x + rnd.choice([" ", " ", " ", "  ", "\t", "   "]))
    texts.append("".join(parts))
open(f"{w}/texts.txt", "w").write("\n".join(x.replace("\n", " ") if i >= 8 else x for i, x in enumerate(texts)).replace("tab\tsplit\nnewline", "tab\tsplit newline") + "\n")
lines = open(f"{w}/texts.txt").read().split("\n")[:-1]
with open(f"{w}/ref.ids", "w") as f:
    for s in lines:
        f.write(" ".join(map(str, t(s, padding="max_length", max_length=64, truncation=True)["input_ids"])) + " \n")
with open(f"{w}/texts_planted.txt", "w") as f:
    f.write("\n".join(s.replace("e", "z", 1) if "e" in s else s + " zzz" for s in lines) + "\n")
EOF
n=$(wc -l < $W/texts.txt); [ "$n" -eq 2000 ] || { echo "FAIL input: $n texts, want 2000"; exit 1; }
.bin/mcv-labels tok $W/tokenizer_pre.json $W/texts.txt $W/got.ids || { echo "FAIL run: mcv-labels tok"; exit 1; }
bad=$(paste -d'|' $W/ref.ids $W/got.ids | awk -F'|' '$1 != $2' | wc -l)
if [ "$bad" -ne 0 ]; then
  paste -d'|' $W/ref.ids $W/got.ids <(cat $W/texts.txt) | awk -F'|' '$1 != $2 {print NR": "substr($3,1,60)}' | head -5
  echo "FAIL ids: $bad of $n texts differ from the reference"; exit 1
fi
.bin/mcv-labels tok $W/tokenizer_pre.json $W/texts_planted.txt $W/planted.ids
pl=$(paste -d'|' $W/ref.ids $W/planted.ids | awk -F'|' '$1 != $2' | wc -l)
[ "$pl" -gt $((n * 9 / 10)) ] || { echo "FAIL plant: only $pl of $n changed texts differ, the gate would pass on an inert tokenizer"; exit 1; }
echo "PASS siglip_tok: $n texts, ids equal the reference (planted: $pl of $n differ)"
