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

| pattern | Python `regex` MB/s | uregex 0.1.0 | uregex 0.2.0 |
|---|---|---|---|
| gpt2 | 14.11 | 12.77 | 30.91 |
| qwen2 | 14.87 | 9.60 | 28.75 |
| qwen35 | 14.64 | 9.44 | 29.15 |
| llama3 | 16.25 | 10.45 | 31.73 |
| spark2_5_3 | 14.15 | 12.88 | 44.75 |

Sparse patterns gain more from the first-character filter: `\p{N}{1,3}`
94 → 137 MB/s, CJK runs 108 → 196 MB/s.

uregex 0.1.0 (fec4575) vs 0.2.1, same corpus and run:

| metric | 0.1.0 | 0.2.1 | change |
|---|---|---|---|
| speed | 9.4 to 14.3 MB/s | 30.9 to 44.1 MB/s | 2.2 to 3.5x faster per pattern |
| bench peak RSS | 68.3 MB | 58.4 MB | -14.5% |
| pattern compile time (bench total) | 6.2 ms | 5.1 ms | -18% |
| compiled pattern (`tools/bench_compile.mojo`) | 166 KB, 0.99 ms | 27.6 KB, 0.81 ms | 6x smaller |
| instruction size (pinned by `test_inst_layout`) | 32 B | 12 B | 2.7x smaller |
| character class size | 32 B | 48 B | +16 B (ASCII bitmap) |
| match size | 16 B | 16 B | no change |

Against Python `regex` on the same runs:

| | Python `regex` | uregex | uregex vs Python |
|---|---|---|---|
| 0.1.0 | 13.6 to 16.4 MB/s | 9.4 to 14.3 MB/s | slower |
| 0.2.1 | 13.9 to 16.4 MB/s | 30.9 to 44.1 MB/s | 2.0 to 3.2x faster |

## Setup

Mojo 1.1 in a project venv (the commands below use `./.venv/bin/mojo`):

```
python3 -m venv .venv && ./.venv/bin/pip install 'mojo==1.1.0' regex
```

## Usage

```mojo
from uregex import Pattern, FullPattern, findall, split_keep

var p = Pattern(r"\p{N}{1,3}|[\p{L}\p{M}]+|\s+(?!\S)|\s+")
for piece in p.findall("héllo 12345"):
    print(piece)                       # héllo, ' ', 123, 45

var chunks = split_keep(r"\p{N}+", "ab12cd")   # ["ab", "12", "cd"]

var g = FullPattern(r"(?P<word>\p{L}+)(\d)?")
for row in g.findall_groups("é1 b"):   # byte spans: [0] match, [i] group i, (-1, -1) unset
    print(row[0].start, row[0].end, row[g.group_index("word")].end)
```

Two engines from one source. `Pattern` is the tokenizer engine: `(...)` does
not capture, and named groups, lookbehind and `\b` raise. `FullPattern` adds
them; that code is compiled only into `FullPattern`, so `Pattern` runs as fast
as if it did not exist. The one-shot helpers (`findall`, `search`,
`split_keep`, `compile`) use `FullPattern`.

Offsets are UTF-8 byte offsets into the String (`search`, `findall_spans`,
`findall_groups`); `findall_cps_offsets` gives codepoint offsets. `findall` and
`split_keep` return slices of the input.

Build with `-I src`. Requires Mojo 1.1 (`max==26.6.0`).

## Supported syntax

Literals and escapes (`\n \t \xHH \x{H..} \uHHHH \UHHHHHHHH`), `.` (no newline),
`^` `$` (text start/end), classes `[...]` `[^...]` with ranges and `\p{}`/`\d\w\s`
inside, `\p{Xx}` `\P{Xx}` for all general categories, `\d \w \s \D \W \S`,
greedy and lazy `* + ? {m} {m,} {m,n}` (`*?` ...), `(?:...)`, `(?i:...)`,
`(?=...)`, `(?!...)`, `|`.

`FullPattern` only: capture groups `(...)`, named groups `(?P<name>...)` and
`(?<name>...)`, word boundaries `\b` `\B`, fixed-length lookbehind `(?<=...)`
`(?<!...)`.

Rejected with a parse error: possessive quantifiers, backreferences,
variable-length lookbehind, unbounded repeats of a nullable expression.

Unicode tables come from Python `regex` (Unicode 17.0 for regex 2026.9.3,
recorded in the generated file's header), case maps included.

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

### Pre-tokenizer coverage

`tools/pretok_harvest.py` downloads `tokenizer.json` only (no weights) for the
top N Hugging Face text-generation models by downloads, runs each model's own
pre-tokenizer (HF `tokenizers`) on the corpus, and finds the mojo-baro family
whose uregex pattern chain splits it identically. Top 250 (2026-10-08): 164
covered (qwen2 78, qwen35 23, llama3 22, gpt-2 12, deepseek-v3 10, gpt-4o 6,
exaone 6, minicpm5 3, bloom 2, deepseek-coder 2), 68 without `tokenizer.json`,
17 without a regex (SentencePiece, or Gemma's literal-space split), 1 unmatched
(falcon-7b: HF applies Punctuation to byte-level characters, splitting UTF-8
sequences; not ported). The o200k and deepseek-coder regexes are HF verbatim in
mojo-baro and pinned in difftest.

```
./.venv/bin/python3 tools/pretok_harvest.py --n 250   # .work/pretok/models.tsv
```

## Packaging

`recipe.yaml` (modular-community shape) builds a precompiled `.conda` and runs
the unit tests against it: `pixi run package` (needs `rattler-build`), output in
`.work/conda/`. Not published.

## License

Apache-2.0, copyright amarbaro.org. See LICENSE and NOTICE.
