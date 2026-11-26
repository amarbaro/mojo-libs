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
single thread, Ryzen 7 7800X3D, load average 6.7 on 16 cores at the run, so the box was not quiet: A/B decisions in the
commits used best of 4 to 10 alternating runs, this table is one run. `zstd -b` reuses its output buffer;
`zstd.decompress` allocates a new one per call, and that cost is in our column.

| input | ours c | libzstd c | c ratio | ours d | libzstd d | d ratio | ours size (B) |
|---|---|---|---|---|---|---|---|
| random | 4445 | 4978 | 0.89 | 10270 | 14728 | 0.70 | 67110414 |
| repeated sentence | 7631 | 7953 | 0.96 | 7304 | 10394 | 0.70 | 6217 |
| executable | 245 | 323 | 0.76 | 1048 | 1563 | 0.67 | 4560703 |
| C sources | 385 | 477 | 0.81 | 1508 | 2219 | 0.68 | 517401 |
| JSON | 284 | 364 | 0.78 | 1084 | 1704 | 0.64 | 3028389 |

Before the work (same harness, load about 9): compress 900, 3239, 238, 361, 249 and decompress 5330, 4759, 669, 1439, 932
MB/s for the five inputs. Compressed sizes did not change. Levels above 3 were not timed; their size gate is unchanged.
What moved it: decode output sized from the frame content size (no growth copies), raw blocks for match-free flat input
without entropy work plus one output reservation, unchecked split fingerprints, 16-byte literal and match copies in
the decoder and in the sequence store, four Huffman streams decoded side by side.

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

`src/` is 4025 lines: `wc -l src/*/*.mojo` (was 230 with the bindings).
