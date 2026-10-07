#!/usr/bin/env python3
# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
"""Differential gate: uregex vs Python `regex` on random Unicode text.

For every pattern, N random strings are matched with regex.finditer and with
.work/uregex-cli (findall semantics). Any difference fails. Offsets are codepoints,
or UTF-8 bytes with --bytes.
Usage: tools/difftest.py [--n 2000] [--seed 0] [--cli .work/uregex-cli] [--bytes]
"""
import argparse
import random
import subprocess
import sys
import tempfile

import regex

TOKENIZER_PATTERNS = {
    "spark2_5_1": r"\p{N}{1,3}",
    "spark2_5_2": r"[一-龥぀-ゟ゠-ヿ]+",
    "spark2_5_3": r"[!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~][A-Za-z]+|[^\r\n\p{L}\p{P}\p{S}]?[\p{L}\p{M}]+| ?[\p{P}\p{S}]+|[\r\n]|\s+(?!\S)|\s+",
    "spark2_5_4": r"\p{N}",
    "qwen2": r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
    "qwen35": r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+|\p{N}| ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
    "gpt2": r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+",
    "llama3": r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
}
FEATURE_PATTERNS = {
    "alt_first": r"ab|a|abc",
    "bounded": r"a{2,3}|b{0,2}c",
    "nested_rep": r"(?:ab+c)*d",
    "class_ci": r"(?i:[a-c]+x)",
    "neg_look": r"\d+(?!\.)",
    "pos_look": r"\p{L}+(?=\s)",
    "not_S": r"\S+",
    "not_D": r"\D{1,4}",
    "cats": r"\p{Lu}\p{Ll}*|\p{Sc}\p{Nd}+|\p{So}",
    "escapes": r"[\t\n\x20-\x2f一\U0001F600]+",
    "dot": r"a.b",
    "anchors": r"^\s*|\s*$",
    "cjk_range": r"[぀-ヿ]+|[^぀-ヿ\s]+",
    "ci_u17": "(?i:\U00016EA0+|\uA7CE|[\U00016EBB-\U00016EBD]x)",
}
ALPHABET = ("abcXYZ 'sT\t\n\r" + "éÉßİıǅ" + "一二三あアㇰ" + "0123٣٤" + "!?.,-_$€" + "😀é́̀"
            + "   " + "ſKΩ" + "\U00016EA0\U00016EBB\U00016EA2\uA7CE\uA7CFx")


def rand_text(rng, k):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, k)))


def oracle(pat, text, bytes_mode):
    if bytes_mode:
        b = lambda i: len(text[:i].encode())
        return [f"{b(m.start())},{b(m.end())}" for m in regex.finditer(pat, text)]
    return [f"{m.start()},{m.end()}" for m in regex.finditer(pat, text)]


def ours(cli, pat, texts, bytes_mode):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
        f.write("\0".join(texts))
        path = f.name
    out = subprocess.run([cli] + (["--bytes"] if bytes_mode else []) + [pat, path], capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise SystemExit(f"cli failed on {pat!r}: {out.stderr[-500:]}")
    return [line.split() for line in out.stdout.split("\n")[: len(texts)]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--cli", default=".work/uregex-cli")
    ap.add_argument("--maxlen", type=int, default=24)
    ap.add_argument("--bytes", action="store_true")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    fails = 0
    for name, pat in {**TOKENIZER_PATTERNS, **FEATURE_PATTERNS}.items():
        texts = ["", " ", "a", "\n"] + [rand_text(rng, a.maxlen) for _ in range(a.n)]
        texts = [t for t in texts if "\0" not in t]
        got = ours(a.cli, pat, texts, a.bytes)
        bad = 0
        for t, g in zip(texts, got):
            exp = oracle(pat, t, a.bytes)
            if exp != g:
                bad += 1
                if bad <= 3:
                    print(f"  DIFF {name}: text={t!r}\n    oracle={exp}\n    uregex={g}")
        print(f"{name:12s} {len(texts)} texts  {'OK' if bad == 0 else f'FAIL {bad}'}")
        fails += bad
    print("PASS" if fails == 0 else f"FAIL: {fails} differences")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
