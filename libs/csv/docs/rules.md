# Verification rules

- Placeholder goldens and PASS prints hid broken parsing: compare CPython-produced field bytes, null flags, writer bytes and errors in the actual gate.
- A smoke case and repeated mutants hid missing branches: compile each distinct behavior mutant, then require the real golden runner to reject it.
- Constant benchmark output claimed unmeasured throughput: benchmark actual work, assert its result, and report wall time plus peak RSS.
- Broad file searches and combined reads produced truncated output: bound each source query and request only task-relevant ranges.
- Guessed `std.io.open` import failed: file opening is a prelude builtin on this toolchain; copy imports from a compiled example.
- Split-view literal comparison failed: materialize `String(view)` for literal comparison when the view carries a different origin.
- Random case 279 found strict EOF after an escaped newline accepted: preserve AFTER_ESCAPED_CRNL while falling through IN_FIELD; only explicit transitions change it.
- Adding iterator vectors shadowed the generator output list: reserve distinct names for accumulators and case inputs; regenerate before committing vectors.
- `ab-step --help` is unsupported: read a local tool's usage header before choosing its flags.
