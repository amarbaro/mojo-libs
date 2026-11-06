# Design

State machine ported from CPython Modules/_csv.c. Mojo reads bytes (Span) and returns List[List[CsvField]]. Unquoted fields are copied into List (owned) in this version; zero-copy optimization deferred. Memory: Reader holds dialect + scratch + state; no per-field allocation beyond list growth.

Bench: not yet measured. Command: mojo run -I src tests/bench.mojo.