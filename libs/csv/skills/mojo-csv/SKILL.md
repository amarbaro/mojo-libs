---
name: mojo-csv
description: Parse and write CSV byte buffers in Mojo with CPython quoting rules
metadata:
  short-description: CSV byte reader and writer
---

# mojo-csv

## When to use
Parse or render complete CSV byte buffers, including malformed UTF-8.
Not for Python file objects, dialect sniffing, dictionaries or streamed output.

## Install
From a clone, pass `-I src` to Mojo 1.2.0. The nightly check records its version.
Run the example: `scripts/cap.sh mojo run -I src examples/quickstart.mojo`.

## Main calls
- `Dialect.excel()`: comma separated fields and CRLF output.
- `Dialect.excel_tab()`: tab separated fields and CRLF output.
- `Dialect.unix_dialect()`: quote every field and write LF.
- `Reader(dialect).read_all(Span(input))`: input is a `List[UInt8]` or byte span;
  returns `List[List[CsvField]]`. The reader owns its dialect.
- `write_all(rows, dialect)`: returns CSV bytes, with a final line terminator.

## Gotchas
`CsvField(data, is_null=False)` owns its byte list. Fields expose `data` and
`is_null`. Read outputs remain valid after the input is released.
STRINGS/NOTNULL distinguish unquoted nulls from quoted empty strings.
Numeric read modes validate ASCII float syntax but return its original bytes.
All non-null writer fields are strings; NONNUMERIC quotes them all.
Field limit is 131072 bytes. Byte controls, not Unicode characters.
Set `has_escape=True` when setting `escapechar`; validation happens at use.
Invalid input raises Error; texts are library-specific.
Whole-buffer parsing materializes rows and fields. Account for output memory.

## Gate
`MOJO=path/to/mojo scripts/ci.sh` builds and checks CPython goldens, an independent
Mojo scanner, compiling behavior mutants, API calls and the quickstart.
`MOJO=path/to/nightly/mojo scripts/nightly.sh` checks the nightly toolchain.
`python3 -I tools/gen_vectors.py` regenerates vectors with CPython 3.14.
See `docs/oracle-coverage.md` for the supported states and interface exclusions.
