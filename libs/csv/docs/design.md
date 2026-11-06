# Design

CPython 3.14 `_csv.c` supplies the licensed state-machine contract. Input is a
whole byte buffer, split into physical lines with an explicit EOL sentinel.
Raw newline bytes survive quoted fields; iterator EOL markers do not become
field content except in the two escape states. Reader calls reset state.

The current `CsvField.data: List[UInt8]` API owns its result. This differs from
the original plan's Span output budget. Preserving that API avoids a caller
lifetime requirement. Unquoted runs copy once directly into their result;
quoted/escaped fields use retained scratch and one result allocation. Rows
are moved, not deep-copied. Writer writes into one result buffer, with no
per-field temporary copy. No extra scratch allocation per ordinary field.

Runtime dialect controls use SIMD comparisons over 16 bytes, then a scalar
tail, instead of a per-dialect classification table. This handles custom byte
controls without table construction or lookup gathers. Only state and special
bytes take the transition function. Chunk loads are bounded by input length.

Sizes: Dialect 40 bytes, Reader 88 bytes, CsvField 56 bytes (Mojo 1.2.0).
Field limit: 131072 bytes, not codepoints. Numeric syntax is ASCII; lexemes are
returned as bytes. Python object types and file APIs are outside this contract.
See oracle-coverage.md for supported raises and exclusions.

## Measurements

Input: 49999950 bytes, 714285 mixed records; both parsers materialize all rows.
CPU 7, compiled `mojo build -O3` binary, three interleaved A/B rounds.
Scanner: 26.71 -> 59.96 MB/s; direct field copies: 43.13 -> 49.45 MB/s.
Separate rounds have different load; compare within each pair only.
Final same-core comparison: Mojo 49.69 MB/s, CPython 61.21 MB/s.
The >= CPython target is not met. No speedup over CPython is claimed.
Peak RSS: scalar 511388 KB, scanner 624116 KB, final 449140 KB;
CPython 562728 KB. Final external wall 1.10 s, Python 1.24 s in RSS runs.
A SIMD first-lane reduction regressed 50.66 -> 46.57 MB/s and was reverted.
The original implementation fails on the same benchmark input; its constant
100 MB/s print was removed. These numbers describe this fixture on a busy box.

Reproduce: `MOJO=path/to/mojo scripts/benchmark.sh`.
Full measurements and commands: benchmarks/csv-reader.txt. The reported target
miss is falsified by a same-input, same-core interleaved comparison reaching
at least CPython throughput with the golden and brute gates still passing.
