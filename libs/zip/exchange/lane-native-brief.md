# Lane brief: mojo-zip, native (no C)

Model: sonnet, effort high. Repo: ~/Projects/mojo/mojo-zip. Report: exchange/lane-native-report.md, then push DONE.

## Goal
Build mojo-zip per docs/plan.md, with one change: no libz. DEFLATE (raw inflate + deflate) and crc32 are pure Mojo.
The vendored src/gzip binds libz.so.1 through OwnedDLHandle: replace its compress/decompress/crc32 with a pure-Mojo
codec under src/deflate (own package), and have zipfile import that. No OwnedDLHandle, external_call or dlopen
anywhere in src/ (gate: `grep -rE "DLHandle|external_call|dlopen" src` is empty).

## Oracle
- Reading: every plan oracle item, against CPython zipfile (tools/oracle.py).
- Inflate: byte-identical output with Python zlib.decompress(wbits=-15) on the plan fixtures plus a corpus of
  random, text, all-zero, incompressible, stored-block, fixed-Huffman and dynamic-Huffman streams, and truncated/corrupt
  streams (error text must match the plan's error contract).
- Deflate: output byte-identical with zlib.compress(level=L, wbits=-15) for L in 0..9 on the same corpus. That means
  porting zlib deflate.c's algorithm (hash chains, lazy match, config table per level, block split), not inventing one.
  If byte-identity for a level is not reached after three repairs: record it in .work/native-failure.md, keep round-trip
  validity (zlib inflates it) and ratio within 1% of zlib for that level, and continue.
- crc32: equal to zlib.crc32 on the corpus.
- Negative control: a mutated codec (one Huffman length off) must fail the gate.

## Rules
- Mojo 1.2 stable, .venv/bin/mojo. Every function `def`; mark `raises`. Read skill mojo-lean first.
- Gate script scripts/check.sh: all oracle rows + negative control; full output to .work/native-gate.txt.
- Commit each sub-step (conventional subject, why body, no attribution lines). Do not push, no remote.
- Bench after the gate: scripts/bench.sh vs tools/bench_ref.py; fix bench/zipbench.mojo to the built API. Numbers into docs/perf.md.
- Update docs/design.md (why native), README licence lines (zlib algorithm port: zlib licence notice).
- Stuck after three repairs on one item: write .work/native-failure.md, move to the next.
