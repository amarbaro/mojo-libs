# Performance

Source: `scripts/bench.sh`, 32 MiB seeded text (`.work/corpus.txt`), 3 runs, level 3 / lz4 default, plus levels 1, 9, 19 on
the first 4 MiB once. Run it: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 scripts/bench.sh`.
Load average 5.7 to 9.0 on 16 cores during the run below (other jobs), so read ratios, not milliseconds.

| | zstd c (ms) | zstd d (ms) | lz4 c (ms) | lz4 d (ms) | peak RSS |
|---|---|---|---|---|---|
| **native Mojo** (this version), 3 runs | 70, 72, 71 | 50, 46, 45 | 30, 28, 28 | 28, 25, 26 | 129 MB |
| Python oracle (libzstd 1.5.7, liblz4 1.9.4), same runs | 55, 49, 53 | 34, 31, 31 | 37, 36, 37 | 36, 34, 36 | 124 MB |
| *v0.2.0, same script, load 12 to 13* | 84, 86, 95 | 48, 73, 51 | 28, 37, 31 | 27, 41, 29 | 123 MB |

Sizes: zstd level 3 4410985 B against libzstd's 4372426 B (+0.9%), lz4 8819229 B, identical to python-lz4's.
The native lz4 is faster than liblz4 here; the zstd encoder takes 1.3 to 1.4x libzstd's time on this text, the decoder
1.4x (Python's call overhead is in its numbers). Peak RSS is 6 MB above v0.2.0: `decompress` now reserves the declared
frame size in one step instead of growing by doubling.

| 4 MiB prefix | native c / d (ms) | native size | Python c / d (ms) | libzstd size |
|---|---|---|---|---|
| level 1 | 9 / 3 | 583253 | 6 / 4 | 583277 |
| level 9 | 42 / 2 | 455442 | 37 / 1 | 456977 |
| level 19 | 2601 / 2 | 312880 | 1343 / 1 | 313057 |

Higher levels cost about 2x libzstd's time (optimal parser, binary tree). Streaming: 128 MiB written and read back through
`ZstdWriter` / `ZstdReader` peaks at 14.2 MB, 1 MiB at 13.5 MB.

## Throughput, level 3

Source: `scripts/bench31.sh`. Five inputs (64 MiB random, 64 MiB of one repeated sentence, first 10 MB of an executable,
2.9 MB of libzstd 1.5.7 C sources and headers, 12 MB of generated JSON lines); ours is `tests/bench31.mojo` (best of 5
per direction, whole buffer in memory), libzstd is `zstd -b3 --single-thread -i1` (CLI 1.5.7). MB/s of input,
single thread, Ryzen 7 7800X3D, load average 7 to 9 on 16 cores, so the box was not quiet: A/B decisions in the
commits used best of 3 to 10 alternating runs, this table is the best of two runs per column. Both sides reuse their
output buffer (ours through `decompress_into`). `zstd -b` writes its frames without a checksum (its output is 4 bytes
shorter than ours on random input), so its decode skips the XXH64 pass that ours does at about 24 GB/s; that pass is
most of the remaining gap on the random and repeated rows.

| input | ours c | libzstd c | c ratio | ours d | libzstd d | d ratio | ours size (B) |
|---|---|---|---|---|---|---|---|
| random | 3982 | 5136 | 0.78 | 9671 | 13295 | 0.73 | 67110414 |
| repeated sentence | 7137 | 7529 | 0.95 | 7250 | 10080 | 0.72 | 6217 |
| executable | 250 | 316 | 0.79 | 1143 | 1447 | 0.79 | 4560703 |
| C sources | 369 | 481 | 0.77 | 1710 | 2157 | 0.79 | 517401 |
| JSON | 281 | 349 | 0.80 | 1235 | 1507 | 0.82 | 3028389 |

Decoder round after v0.3.0 (decode only, best of 3x7, MB/s): unconditional first copy of literals and far matches,
exe 1067 -> 1180, C sources 1544 -> 1725, JSON 1094 -> 1340. Tried and dropped for no gain: inlining the bit reader's
end check, five Huffman symbols per reload, an AVX-512 XXH64, a prefetch of the match source (slower: the stall is
the match load waiting on just-stored literal bytes, not a cache miss).

Before the work (same harness, load about 9): compress 900, 3239, 238, 361, 249 and decompress 5330, 4759, 669, 1439, 932
MB/s for the five inputs. Compressed sizes did not change. Levels above 3 were not timed; their size gate is unchanged.
What moved it: decode output sized from the frame content size (no growth copies), raw blocks for match-free flat input
without entropy work plus one output reservation, unchecked split fingerprints, 16-byte literal and match copies in
the decoder and in the sequence store, four Huffman streams decoded side by side.

## Throughput, level 9 (issue #34)

Source: `LEVELS="3 9" ZSTD=<1.5.7 CLI> scripts/bench31.sh`, same five inputs and harness as above, libzstd 1.5.7 built
from source (`zstd -b9 --single-thread -i1`; the system CLI is 1.6.0 by now). MB/s, best of two alternating rounds
per cell (each round is best of 5 on our side), load average 4 to 8 on 16 cores, so read the ratios. "Before" is
the tree at v0.4.0 plus the level argument of the harness.

| input | before c | after c | libzstd c | c ratio before | c ratio after | after d / libzstd d | size before (B) | size after (B) | libzstd (B) |
|---|---|---|---|---|---|---|---|---|---|
| random | 646 | 3615 | 3671 | 0.17 | 0.98 | 11609 / 20056 (0.58) | 67110414 | 67110414 | 67110414 |
| repeated sentence | 951 | 1878 | 1773 | 0.52 | 1.06 | 7340 / 10560 (0.70) | 6217 | 6217 | 6232 |
| executable | 41 | 83 | 96 | 0.43 | 0.86 | 1345 / 1747 (0.77) | 4452668 | 4358161 | 4363739 |
| C sources | 81 | 115 | 127 | 0.63 | 0.90 | 1821 / 2519 (0.72) | 426589 | 424991 | 425598 |
| JSON | 41 | 80 | 88 | 0.49 | 0.90 | 1560 / 1950 (0.80) | 2796051 | 2692423 | 2692964 |

What moved it, one commit each:

- Lazy skipping (`fc9fe45f`): after 2 KiB without a match the parser's step passes 8 and only the searched positions
  enter the match finder's tables, as in libzstd. Random input went from 646 to about 3700 MB/s; before, every skipped
  byte was hashed and inserted.
- The row match finder (`36046751`): libzstd uses it, not the hash chain, for greedy, lazy and lazy2 (levels 5 to 12)
  on windows over 16 KiB. Rows of 16 to 64 entries with a tag byte each, one SIMD compare per search, hashes computed
  8 positions ahead with the rows prefetched, rows on cache lines, long matches entered only at both ends. Executable
  42 -> 78, C sources 81 -> 119, JSON 40 -> 77, repeated sentence 861 -> 2214 MB/s; JSON at level 10 19 -> 56 and at
  level 12 9 -> 35. Peak RSS of the bench at level 9 on the executable: 65.0 -> 59.9 MB (no chain table, a 2 MiB tag
  table instead).
- The gain of a held repeat-offset match (`2ded0965`): the lazy parsers charged it a full offset's cost, libzstd
  charges 0. Level-9 output was 2.0% (executable) and 3.8% (JSON) larger than libzstd's; it is now within 0.1%.

Level 3 is unchanged by these commits (it uses the double-fast finder): in the same runs its compress ratios to
libzstd were 0.73 to 0.98 before and 0.71 to 0.95 after, sizes identical. The decoder was not touched. The smaller level-9 frame of the executable decodes about 8%
slower per output byte than the old one in our decoder (1523 -> 1400 MB/s, best of 3x7) and 13% slower in libzstd's
(1723 -> 1503): the denser parse has more sequences. libzstd's own level-9 frame of that file decodes at 1383 in ours.

Left at level 9: 10 to 14% on real data, spread over the candidate loads of the row search (cache misses on match
positions, the same in libzstd) and the code around it; no single cause stood out in `perf annotate`.

## Size against libzstd, every level

2 MiB of the seeded text, `zstd.compress(data, level)` against Python `zstandard` at the same level (both decode to the
source under Python). The gate holds every row of its fixtures to 5% (+16 B for tiny inputs); this table is the large-input
view. Worst gap over all 24 levels per input: text +0.9% (level 4), 870 KB of C sources +1.3% (level 3), 940 KB shared object
+0.8% (level 17), 2.5 MB binary slice +1.9% (level 13). Byte identity with libzstd is not a goal.

| level | native (B) | libzstd (B) | gap |
|---|---|---|---|
| -5 | 285333 | 291633 | -2.2% |
| -1 | 283216 | 286624 | -1.2% |
| 1 | 278650 | 278497 | +0.1% |
| 2 | 282944 | 282553 | +0.1% |
| 3 | 275369 | 272826 | +0.9% |
| 4 | 275365 | 272818 | +0.9% |
| 5 | 234639 | 234554 | +0.0% |
| 6 | 231906 | 231379 | +0.2% |
| 7 | 221214 | 221999 | -0.4% |
| 8 | 218180 | 218870 | -0.3% |
| 9 | 217940 | 218878 | -0.4% |
| 10 | 209379 | 209757 | -0.2% |
| 11 | 201979 | 202296 | -0.2% |
| 12 | 201979 | 202296 | -0.2% |
| 13 | 183390 | 194036 | -5.5% |
| 14 | 170019 | 180827 | -6.0% |
| 15 | 169991 | 173879 | -2.2% |
| 16 | 170186 | 170241 | -0.0% |
| 17 | 164658 | 164655 | +0.0% |
| 18 | 164134 | 164027 | +0.1% |
| 19 | 153161 | 153180 | -0.0% |
| 20 | 153161 | 153180 | -0.0% |
| 21 | 153161 | 153180 | -0.0% |
| 22 | 153161 | 153180 | -0.0% |

Rows 5 to 12 predate the row finder and the repeat-offset gain fix (issue #34). On 2 MiB of the current seeded text
they now sit within 0.1% of libzstd on either side (level 9: 229420 B against 229403; before: 228448, 0.4% under),
and 2 to 4% closer on binary and JSON input, where they were larger.

`src/` is 4346 lines: `wc -l src/*/*.mojo` (was 230 with the bindings).
