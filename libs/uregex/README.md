# mojo-uregex

Unicode-aware regular expressions for Mojo, built for the pre-tokenizers of LLM
tokenizers (GPT-2, Qwen, Llama 3, DeepSeek, Spark) and verified against Python's
`regex` module by differential testing.

It is the complement of [`mojo-regex`](https://github.com/msaelices/mojo-regex),
which is a fast DFA/NFA engine for byte-class patterns. `uregex` exists for the
patterns that engine lists as missing:

| feature | example | in tokenizers |
|---|---|---|
| Unicode general categories | `\p{L}` `\P{N}` `[\p{L}\p{M}]` `\p{Lu}` | every BPE pre-tokenizer |
| negated shorthand classes | `\S` `\D` `\W` | `\s+(?!\S)` |
| lookahead | `(?!...)` `(?=...)` | `\s+(?!\S)` |
| case-insensitive groups | `(?i:'s\|'t\|'re)` | Llama 3, Qwen |
| bounded repeats | `\p{N}{1,3}` | Llama 3, Spark |
| PCRE leftmost-first alternation | `ab\|abc` matches `ab` | all of them |

Matching runs directly on the UTF-8 bytes of the input with a backtracking VM.
`Match` offsets (`search`, `findall_spans`) are byte offsets into the String;
`findall_cps_offsets` returns codepoint offsets. `findall` and `split_keep`
slice the input without copying it to codepoints.

## Performance

`tools/bench.sh`: `findall` over a 1.05 MB mixed-script corpus, best of 5,
Mojo 1.1.0, CPU. Match counts equal Python `regex` for every pattern.

| pattern | Python `regex` MB/s | uregex 0.1.0 | uregex now |
|---|---|---|---|
| gpt2 | 14.97 | 12.77 | 34.10 |
| qwen2 | 14.85 | 9.60 | 32.65 |
| qwen35 | 13.88 | 9.44 | 32.62 |
| llama3 | 16.17 | 10.45 | 35.80 |
| spark2_5_3 | 13.85 | 12.88 | 45.19 |

Compiled pattern (`tools/bench_compile.mojo`): 27.5 KB and 0.83 ms each
(was 166 KB and 0.99 ms). Peak RSS of the bench 58 MB (was 68 MB).

## Setup

Mojo 1.1 in a project venv (the commands below use `./.venv/bin/mojo`):

```
python3 -m venv .venv && ./.venv/bin/pip install 'mojo==1.1.0' regex
```

## Usage

```mojo
from uregex import Pattern, findall, split_keep

var p = Pattern(r"\p{N}{1,3}|[\p{L}\p{M}]+|\s+(?!\S)|\s+")
for piece in p.findall("héllo 12345"):
    print(piece)                       # héllo, ' ', 123, 45

var chunks = split_keep(r"\p{N}+", "ab12cd")   # ["ab", "12", "cd"]
```

Build with `-I src`. Requires Mojo 1.1 (`max==26.6.0`).

## Supported syntax

Literals and escapes (`\n \t \xHH \x{H..} \uHHHH \UHHHHHHHH`), `.` (no newline),
`^` `$` (text start/end), classes `[...]` `[^...]` with ranges and `\p{}`/`\d\w\s`
inside, `\p{Xx}` `\P{Xx}` for all general categories, `\d \w \s \D \W \S`,
greedy `* + ? {m} {m,} {m,n}`, `(?:...)`, `(?i:...)`, `(?=...)`, `(?!...)`, `|`.

Rejected with a parse error: lazy/possessive quantifiers, capture groups and
backreferences, `\b`, lookbehind, unbounded repeats of a nullable expression.

## Verification

`tools/gen_unicode.py` derives every class table from the Python `regex` module,
so classes are equal to the oracle by construction (the file header records the
`regex` and Unicode versions). `tools/difftest.py` then matches every pattern
above, plus feature probes, against `regex.finditer` on random Unicode strings:

```
./.venv/bin/mojo build tools/uregex-cli.mojo -I src -o .work/uregex-cli
./.venv/bin/python3 tools/difftest.py --n 5000 --maxlen 80          # codepoint offsets
./.venv/bin/python3 tools/difftest.py --n 5000 --maxlen 80 --bytes  # byte offsets
./.venv/bin/mojo run -I src tests/test_uregex.mojo
```

A negative control (oracle fed a different pattern) fails, so the gate is live.
`tools/gate.sh` runs all of the above.

## Packaging

`recipe.yaml` (modular-community shape) builds a precompiled `.conda` and runs
the unit tests against it: `pixi run package` (needs `rattler-build`), output in
`.work/conda/`. Not published.

## License

Apache-2.0, copyright amarbaro.org. See LICENSE and NOTICE.
