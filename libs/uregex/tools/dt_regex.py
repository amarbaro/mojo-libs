#!/usr/bin/env python3
# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
"""Oracle side of tools/difftest-real.sh: one text per stdin line, one answer line per text: `[s,e s,e ]`
in codepoints (the uregex-cli format, bracketed so no answer is empty). Pattern by name from tools/difftest.py."""
import sys

import regex

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from difftest import TOKENIZER_PATTERNS  # noqa: E402

pat = regex.compile(TOKENIZER_PATTERNS[sys.argv[1]])
for text in sys.stdin.buffer.read().decode().split("\n")[:-1]:
    print("[" + "".join(f"{m.start()},{m.end()} " for m in pat.finditer(text)) + "]")
