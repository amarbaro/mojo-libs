# Design

UUID is one UInt128: 16 inline bytes. No heap per UUID value.
The hot paths are parsing and rendering a canonical 36-byte UUID.
Formatting writes a fixed 36-byte stack buffer and returns one owned String.
Hex formatting uses a 32-byte stack buffer. Byte conversion uses 16 inline bytes.
Parsing normalizes CPython forms before scanning digits; normalization owns strings.
Hashing uses mojo-hashlib's MD5 and SHA-1, not a Python runtime.
Entropy comes from libc getrandom, checked for failure and partial reads.
clock_gettime provides nanosecond resolution; wall-clock timestamps may go backwards.
Explicit generator state handles repeats, rollback and the 42-bit v7 counter rollover.
One-shot functions have no global monotonic state. Caller-owned state avoids hidden
shared mutable storage and makes deterministic tests possible.

RFC 9562 Appendix A.2-A.6/B.1-B.2 supply all generator goldens; Sections 5.9,
5.10 and 6.6 supply constants. No generated golden files are accepted.
A.6 uses injected generator state and an assembler cross-check: CPython clears
the counter MSB and cannot generate that exact initial seed without state injection.
Error messages come from CPython v3.14.0 uuid.py, verified by tools/check_reference.py.
10,000 independent bit-by-bit formatter/parser cases exercise byte round trips.
256 generated UUIDs are compared directly with CPython for string, hex, bytes_le,
clock sequence and node. Mutants must compile before the gate can kill them.

Baseline, same 10,000 operations: parse 998 ns/op, str 542 ns/op, uuid4 63 ns/op;
initial wall 0.02 s, peak RSS 12048 KB.
Command: scripts/run-capped.sh mojo build -O3 -I src -I ../mojo-hashlib-public/src
 tests/bench.mojo -o .work/bench-after
Command: scripts/run-capped.sh /usr/bin/time -f '%e s %M KB' .work/bench-after
Reference: scripts/run-capped.sh python3 -I tools/bench_ref.py

Rejected: Python runtime in the library, UUID heap allocation, hardware-node lookup,
and fabricated fixtures generated from the implementation being checked.

Three alternating rounds pinned to CPU 0 (10,000 calls per operation), medians:
parse 987 -> 44 ns/op; str 623 -> 97 ns/op; uuid4 46 -> 50 ns/op.
Wall 0.02 -> 0.01 s; peak RSS 10124 -> 10544 KB (process startup included).
UUID remains 16 bytes. Source 320 -> 491 lines; 10429 -> 16907 source bytes.
CPython reference: parse 837.8, str 391.9, uuid4 697.3 ns/op, RSS 10524 KB.
Run `MOJO=mojo scripts/bench.sh` with .work/bench-before preserved for paired results.
Short runs show host noise, especially uuid4; no RNG speed improvement is claimed.
