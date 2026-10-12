# U5 report: gguf-py scripts as one Mojo CLI (`lane-u5`)

Result: **PASS 14/14**, gate exit 0. Code commits `d072fc0` (reader) and `61bd576` (tool, gate 14/14).

## Gate output (`tests/u5-gate.sh`, final run)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   build
ok   dump-q4k
ok   dump-flash-notensor
ok   dump-json
ok   dump-markdown
ok   dump-offsets
ok   hash-q4_0
ok   hash-nolayer
ok   set-int
ok   set-missing-key
ok   endian-big-q8
ok   endian-big-q4k
PASS 14/14
```

## Files and LOC

| file | lines (`wc -l`) | status |
|---|---|---|
| `src/gguf_tool.mojo` | 826 | new: CLI, dump (text, json, markdown), hash, set-metadata, convert-endian |
| `src/gguf/fmt.mojo` | 323 | new: exact `%.Nf`, str.title, repr, json strings, numpy float32 str |
| `src/gguf/sha.mojo` | 201 | new: streaming SHA-1 and SHA-256 |
| `src/gguf/values.mojo` | 129 | new: in-place value reads, three render dialects, leaf walker |
| `src/gguf/quant.mojo` | 63 | new: GGML type table generated from the pinned `constants.py` |
| `src/gguf/model.mojo` | 325 (was 297) | U1 reader: type chains, leaf counts, record offsets, big-endian reads |
| `src/gguf/__init__.mojo` | 1 | unchanged |
| total under `src/` | 1868 | |

Lines are `wc -l`, not code-only counts. `README.md` gained the rows for the new files and `tests/u5-gate.sh`.

## Wall and peak RSS (`/usr/bin/time`, 506 MB Q8_0 fixture, final binary)

```
hash (layers)              14.44 s   21432 KB
hash --no-layer             8.66 s   21480 KB
dump --markdown (Q8_0)      0.03 s   21468 KB
convert-endian big (Q8_0)   1.14 s   21500 KB
```

Reference, `gguf_hash.py` on the same file: 4.70 s, 857220 KB. Hash output is byte-identical to the script.
Hot path for hash: the scalar SHA compression over five hashers per byte (layer and total, SHA-1 and SHA-256,
plus the uuid SHA-1). Before the block-direct update change the same run was 18.57 s; the change saved about a quarter.
The remaining gap is scalar code against hashlib's SHA-NI; I did not chase it further.

## Beyond the gate (checked by hand against the scripts, not in `tests/`)

- Big-endian file (`convert-endian big` output): `dump`, `dump --json`, `dump --json --json-array` and
  `dump --markdown` byte-identical to `gguf_dump.py`; `--data-offset` and `--data-alignment` agree.
- `set-metadata` parity, stdout/exit/file: prompt declined, prompt accepted (edit verified by re-dump), dry-run,
  equal value (no write), float32 field, u32 overflow (exit 1), negative into unsigned (exit 1), negative into
  a signed field, string key (exit 1).
- `convert-endian` on Q8_0: declined prompt, `--dry-run`, and the already-native order leave the file unchanged.
- Q4_K's `token_embd` is Q5_0, so `convert-endian` refuses it before any write and before the prompt, exit 1 in both.
  This is what the gate's `endian-big-q4k` case expects.

## Design calls worth a reviewer's look

1. **Big-endian reads in the U1 reader.** gguf-py reads both byte orders and the gate's conversion output
   can't be dumped without it. The change is additive: `big` is set when the version's low half is zero, and
   `_int` honours it. `rewrite` refuses big-endian input rather than mixing byte orders in the output.
2. **numpy float32 `str()` is not Python `repr()`.** Markdown scalars and array elements use numpy's float32 rule:
   scientific from 1e6 and below 1e-4, where Python switches at 1e16. Found by the gate (`qwen2.rope.freq_base`
   prints `1e+06` in the markdown oracle, `1000000.0` in the text dump). `np_float32` re-renders Mojo's shortest
   float32 digits with numpy's thresholds. Checked against numpy on 34 values: 33 equal. The 34th (1.4e-45) differed
   only because the probe's `Float32(1.4e-45)` literal flushed to zero; the same subnormal built from its bits prints `1e-45`, as numpy does.
3. **`%.Nf` is exact.** Python rounds the binary value, not the shortest decimal. `fixed` expands the mantissa
   in base 1e9 and rounds half-even from the exact digits, so ties like `2.675` come out as Python does.
4. **Quant table from the pinned source.** The 35 rows come from `GGML_QUANT_SIZES` by script, not retyped.
5. **Own SHA.** mojo-baro's `sha256` takes a whole span, which would put a tensor in memory. The round
   constants are copied from it (64 extracted and checked); the rest is streaming SHA-1 and SHA-256.
6. **Prompts go to stdout.** `input()` writes its prompt to stdout, as Python's does. The gate compares it
   (`YES, I am sure> `). The script's log lines go to stderr in Python and are not reproduced here.

## What was hard

- Matching Python's **value rendering**, not the format strings: `repr` of nested arrays, the `[..., ...]`
  truncation at six elements, `contents(slice(6))` flattening nested arrays, and the 60-character string cut
  (counted in code points, not bytes).
- The markdown table: column width from the widest cell including the header, code-point widths, and
  `#16x` hex fields.
- The float32 str rule above, which only the gate exposed.
- Mojo API friction: no `len(String)`, no `String` slicing, no variadic `List` constructors, `print(file=…)`
  takes a `FileDescriptor`, and `Span` slicing works where `String` slicing does not.

## Repair count

- Compile repairs: 4 rounds (`print(file=)` type, `len(String)` and `String` slicing, list-literal and
  `List[String](…)` forms, a `UInt64` shift operand). No error repeated after its fix. No `.work/u5-failure.md`.
- Gate repairs: 1 (the numpy float32 markdown rule; the first run was 13/14, the only diff was that line).
- Speed repair: 1 (block-direct SHA update, 18.6 s to 14.4 s, output unchanged).

## Not done, or not exercised by the gate

- **Nested arrays** (dump, json-array, markdown, convert-endian) are implemented from the reader's type chain but
  no fixture here has one, so they are unverified.
- **Version 2 files.** gguf-py accepts v2; `Gguf` still rejects anything but v3, as U1 did. Unverified either way.
- **`set-metadata` on `GGUF.*` header fields.** gguf-py's `reader.fields` includes `GGUF.version`,
  `GGUF.tensor_count` and `GGUF.kv_count`, so it could set them; this tool looks up KVs only.
- **argparse details.** Exit 2 on usage errors matches; the help text and the messages on stderr do not.
  With no subcommand arguments the tool prints a one-line usage and exits 0 (argparse prints full help).
- **Non-ASCII repr.** `py_repr` escapes C0 controls and the C1 range (U+0080 to U+009F) and passes other
  non-ASCII text through. Python also escapes non-printable Unicode such as U+00A0 and U+200B. The fixtures
  exercise only printable text, so this is unverified for other input.
- **Numeric arguments to `set-metadata`.** Integers take an optional sign, surrounding whitespace and decimal
  digits. Python's `int()` also accepts underscores between digits, which this tool rejects. Float text is parsed
  by Mojo's `Float64(String)`; only plain decimal and exponent forms were tried.
- **Logging.** Python's `INFO`/`WARNING` lines on stderr are not produced; the gate does not compare stderr.
