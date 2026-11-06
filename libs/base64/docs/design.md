# Design

Inputs are non-owning Span[UInt8] views; outputs own List[Byte] buffers.
The byte codecs use scalar integer grouping and comptime alphabet strings.
No runtime Python dependency. The reference is CPython 3.14.8/3.14.9.

Base64 validation follows current binascii branch order, including invalid
alphabet before post-padding errors and valid-data counts in length errors.
Duplicate altchars use the last mapping, matching bytes.maketrans.
Base32 checks input length, map01 length, alphabet, then padding count.
The tests compare output bytes and full error messages, not Python error types.
Mojo errors use Error; empty optional byte lists represent Python None.

Memory: decode currently copies the input for translation/casefold, Base32
also copies padding scratch. Several append APIs compute a temporary result.
The result-only allocation target in the initial plan is not achieved.
No per-character String allocations occur on the codec success path.
Reverse lookup is scalar; no aligned SIMD lookup-table claim is made.

Performance is measured with real calls on 64 MiB x3 and 1 KiB x10000.
Three paired rounds on CPU 15, medians: before/after 64 MiB encode
0.402/0.388 GB/s, decode 0.180/0.197 GB/s; 1 KiB encode 0.589/0.618,
decode 0.182/0.199 GB/s. CPython: 0.745/0.648 GB/s large encode/decode,
1.105/0.775 GB/s small. Full benchmark before/after: 1.98/1.83 s;
peak RSS median 448540/448340 KB. Load average 15.47 on 16 CPUs.
This is a correctness repair; loaded-host timings do not prove a speed win.
The old literal 1 GB/s benchmark was removed because it measured nothing.

Build: scripts/capped.sh .venv/bin/mojo build -O3 -I src tests/bench.mojo -o .work/bench.
Compare: scripts/bench.sh BASELINE_BINARY .work/bench (three alternating rounds).
Reference: scripts/capped.sh python3 -I tools/bench_ref.py.

Verification: committed CPython vectors, a bit-at-a-time Mojo encoder oracle
on 10000 seeded random inputs (0..4096 bytes), append replay, and compiling
behavioral mutants. scripts/ci.sh runs the full stable gate; scripts/nightly.sh
precompiles the package and runs the same golden/brute/API/example entry points.
The CPython 3.14.0 strict pad order changed in maintenance versions; docs and
goldens name the tested maintenance versions rather than claiming all 3.14.
