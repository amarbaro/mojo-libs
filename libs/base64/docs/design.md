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

Memory: codecs stream directly from non-owning Span views without
input-sized scratch buffers. Base32 uses fixed inline arrays for quanta tails.
All append APIs write directly into caller buffers, preserving prefixes.
No per-character String allocations occur on the codec success path.
Lookup tables are stack-backed Array[Int8, 256]; no dynamic tables are used.

Performance is measured with real calls on 64 MiB x3 and 1 KiB x10000.
Three paired rounds on CPU 15, medians: before/after 64 MiB encode
0.411/0.581 GB/s, decode 0.215/0.707 GB/s; 1 KiB encode 0.610/0.696,
decode 0.213/0.701 GB/s. CPython: 0.787/0.710 GB/s large encode/decode,
1.106/0.807 GB/s small. Full benchmark before/after: 1.71/0.82 s;
peak RSS median 448492/270144 KB. Load average 12.3 on 16 CPUs.
Large-input decode within 0.5% of CPython (0.707 vs 0.710 GB/s); encode (-26% at 64 MiB, -37% at 1 KiB), small decode (-13%) and peak RSS (+8%, 270 vs 251 MB) remain worse; release blocked on perf.
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
