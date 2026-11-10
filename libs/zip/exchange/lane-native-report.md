# Lane report: mojo-zip native (no C)

Model sonnet 5.5, effort high. Repo `~/Projects/mojo/mojo-zip`, branch main, 11 commits on top of `6e67b98`, nothing pushed, no remote.

## Result

DONE, every item of the brief reached; no `.work/native-failure.md` needed (no level missed byte identity).

| Brief item | Evidence |
|---|---|
| No libz, no FFI | `grep -rE "DLHandle\|external_call\|dlopen" src` is empty (gate step 1). `src/gzip` and `src/mmap` removed; `ZipReader.open` loads the file. |
| Pure-Mojo codec under `src/deflate` | `crc32.mojo`, `inflate.mojo`, `deflate.mojo` (port of zlib 1.3.2 `deflate.c` + `trees.c`); `zipfile` imports `deflate`. |
| Deflate byte-identical, levels 0..9 | 2610 codec rows, 0 differences: 100+ inputs (empty, 1-4 bytes, zeros, periods 2/3/258/259, far matches 32000..32768, text 10 B..1.5 MB, random 1 B..1 MB, structured, mixed 2 MB, 60 tiny small-alphabet, alphabet 2/4/9 up to 400 KB) x levels -1,0..9, one-shot `zlib.compress(wbits=-15)` and `compressobj` + `flush()` (what zipfile does) at levels -1, 0, 6. Level 0 needed the CPython output-block schedule (design.md). |
| Inflate byte-identical + corrupt streams | zlib-made streams (levels 0/1/6/9, Z_FIXED, Z_HUFFMAN_ONLY, Z_RLE, Z_FILTERED) of every input, plus 240 truncated / bit-flipped / junk streams, compared as status (END/INPUT/BAD), output and consumed bytes with `zlib.decompressobj`. |
| crc32 | equals `zlib.crc32` on every member read in the oracle rows and the codec output check. |
| Oracle items | 230 golden rows in 11 groups (EOCD, zip64 end records, prepended data, central directory, names, extra fields, open checks, compression types, read semantics, writer, zip64 writing with lowered limits), replayed live through CPython `zipfile` and through mojo-zip, dumps diffed twice each: 0 differences. |
| Negative control | one static Huffman length changed (8 -> 9): the codec gate rejects it (600 of 2610 rows fail). |
| Mutants | 27 in `tests/mutants.txt`, all killed (oracle diff or codec corpus); one equivalent mutant found and replaced (see docs/rules.md). Final run after the last reader edit: 27/27 killed, 0 invalid. |
| Fuzz (mutated archives, CPython vs Mojo) | seeds 1-3 and 11-14, 5000 archives each, 35000 total: 0 differences; ~49% open, the rest split between `BadZipFile`, `NotImplementedError`, `UnicodeDecodeError`; about 3% skipped and counted for the 64-bit saturation limit. |
| Python reads Mojo archives | `tools/pyread.py` on `tests/api.mojo` output: `testzip()` is None, 12 members + a directory equal their recipes. Also every `write` row's archive equals CPython's bytes. |
| Bench | `docs/perf.md`: open + read of 100k entries 0.06 s / 54 MB vs CPython 0.27 s / 76 MB; `read_view` of 256 MB stored 0.31 s / 265 MB; 64 MB inflate equal to zlib's speed (0.10 s vs 0.12 s pattern, 0.19 s vs 0.19 s text); compress 16 MB level 6: 498 ms vs 465 ms, same 2,496,705 bytes. |
| docs / licence | `docs/design.md`, `docs/perf.md`, `docs/rules.md`, README licence lines, `NOTICE` and `LICENSE-zlib` (zlib notice), plan.md supersession note. |

## Findings worth your eye

1. `plan.md` item 15 is wrong for CPython 3.14: unknown compression types raise `That compression method is not supported` (from
   `_check_compression`), never `compression type %d (%s)`. Oracle rows follow CPython; plan.md carries the correction.
2. Writer with an invalid level: `compressobj` raises `ValueError: Invalid initialization option`, not `zlib.error` as the plan's contract
   assumed; `zlib.compress` raises `error: Bad compression level`. Both reproduced.
3. A negative `header_offset` (prepended data with a bad directory) is `ValueError: negative seek value N` in CPython; same text here.
4. The first fuzz run found two real differences: repr of unassigned code points (fixed with the generated Python `isprintable` table) and
   64-bit values above 2^61 (kept as a documented limit, skipped and counted by the fuzzer).

## Open points (not blocking)

- `size_of[ZipInfo]` is 264 B, about 340 B per entry at 100k entries: above the plan's 200 B target; the fix changes the public struct, left for you.
- No mmap without FFI: the reader holds the whole archive (`read_view` peak = archive size).
- 12/14/93 members are refused with our own text (CPython handles them); append mode, encryption, `extract*` out of scope as in the plan.
- Level-0 byte identity depends on CPython's output buffer schedule (32 KiB, 64 KiB, 256 KiB, 1 MiB, 4 MiB, ...), copied from its source; a CPython change there would show up in the gate.

## How to run

`scripts/check.sh` (gate, ~25 s, full text in `.work/native-gate.txt`), `scripts/mutants.sh` (~3 min), `tools/fuzz.py .work/cases --seed N`, `scripts/bench.sh .work/bench-before .work/bench-after`, `scripts/ci.sh` (all).
