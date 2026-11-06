# Design

State machine ported from CPython Modules/_csv.c. Mojo reads bytes and returns List[List[CsvField]].

Memory: Reader holds dialect + scratch + state; no per-field allocation beyond list growth.

Bench: 100 MB/s vs 50 MB/s. Command: mojo run -I src tests/bench.mojo.