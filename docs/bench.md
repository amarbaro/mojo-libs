# Benchmarks

Each row is the library's own `scripts/bench.sh`: the Mojo library and the reference it imitates do the same work
on the same input in the same session, 3 runs each, median shown (mojo-uuid: Python side ran once).
Single runs spread up to 60% (XLM-R Mojo 103 to 171 ms, BERT crate 270 to 357 ms); all runs are in the receipts. `scripts/bench-all.sh` ran one library at a time
on a freshly booted box with background services stopped (1-min load 0.7 to 1.5 at each start).

Machine: Ryzen 7 7800X3D, 64 GB, Linux 7.2. Mojo 1.2.0, CPython 3.14.10. 2026-11-10.
Receipts: full logs in `docs/bench-receipts/2026-11-10/<repo>.log`; the commit column is the library's HEAD at the run.

| Library @ commit | Job | Mojo | Reference | Reference is | Ratio |
|---|---|---|---|---|---|
| mojo-tokenizers @ d8bc9cb | encode 1 MB, GPT-2 BPE | 65 ms | 271 ms | HF `tokenizers` 0.23.3 (Rust), 1 thread | 4.2x |
| | encode 1 MB, Llama 3 | 65 ms | 244 ms | same | 3.8x |
| | encode 1 MB, Qwen2.5 | 71 ms | 301 ms | same | 4.2x |
| | encode 1 MB, BERT WordPiece | 64 ms | 295 ms | same | 4.6x |
| | encode 1 MB, T5 Unigram | 86 ms | 232 ms | same | 2.7x |
| | encode 1 MB, XLM-R Unigram | 111 ms | 236 ms | same | 2.1x |
| mojo-msgpack @ 6f83ced | decode 4.9 MB (1.3 M nodes) x5 | 84 ms | 235 ms | `msgpack` 1.1 (C extension) | 2.8x |
| | encode 4.9 MB | 4 ms | 25 ms | same | 6x |
| mojo-log @ 61d442f | 1 M JSON lines | 766 ms | 4008 ms | Python `logging` | 5.2x |
| mojo-struct @ 1645720 | unpack_from, per record | 25 ns | 346 ns | Python `struct` | 14x |
| | pack_into, per record | 51 ns | 182 ns | same | 3.6x |
| mojo-base64 @ 2d49578 | b64 encode 1 KiB / 64 MiB | 2.28 / 1.60 GB/s | 1.35 / 0.95 GB/s | Python `base64` (C) | 1.7x / 1.7x |
| | b64 decode 1 KiB / 64 MiB | 1.42 / 1.54 GB/s | 0.93 / 0.83 GB/s | same | 1.5x / 1.9x |
| mojo-uuid @ bacef5b | parse | 7.7 ns | 590 ns | Python `uuid` | 76x |
| | uuid4 | 28 ns | 549 ns | same | 19x |
| mojo-bench @ c02c02e | stats 20x(n=200, B=1000) | 12 ms | 1445 ms | Python `statistics` + bootstrap | 120x |
| mojo-safetensors @ f536d0c | read header, 1500 tensors | 1 ms | 159 ms | `safetensors` (Rust) + numpy | * |
| mojo-gguf-core @ 088f7a2 | read 882 B file | <1 ms | 94 ms | `gguf` Python package | * |
| mojo-aio @ 962b967 | HTTP echo, req/s | 154 k | 72 k / 154 k | asyncio / uvloop | 2.1x / 1.0x |
| mojo-posix @ 0d9f0ad | poll loop | 398 ms | 453 ms | Python `select` / `os` | 1.1x |
| mojo-gzip @ d5976aa | inflate 21.8 MB | 22 ms | 20 ms | Python `zlib` | 0.9x ** |
| mojo-zstd @ b590668 | zstd -3 compress / decompress 32 MiB | 53 / 29 ms | 51 / 30 ms | `zstandard` | 1.0x ** |
| | lz4 compress / decompress | 32 / 24 ms | 36 / 31 ms | `lz4` | 1.1x / 1.3x ** |

Second batch, same session and conditions (`scripts/bench-pair.sh`, which builds `tests/bench.mojo` and runs
`tools/bench_oracle.py` for libraries without their own `scripts/bench.sh`):

| Library @ commit | Job | Mojo | Reference | Reference is | Ratio |
|---|---|---|---|---|---|
| mojo-json @ 65ad7e9 | parse 4 MB x20 | 189 ms | 708 ms | Python `json` (C) | 3.7x |
| | dumps 4 MB x20 | 287 ms | 393 ms | same | 1.4x |
| mojo-csv @ aad4381 | stream 50 MB | 176 ms | 464 ms | Python `csv` (C) | 2.6x |
| | owned rows 50 MB | 382 ms | 514 ms | same | 1.3x |
| | write 50 MB | 88 ms | 391 ms | same | 4.4x |
| mojo-sqlite @ 377f3e7 | 200 k inserts, one transaction | 80 ms | 184 ms | Python `sqlite3` (same libsqlite3) | 2.3x |
| | full scan | 25 ms | 84 ms | same | 3.4x |
| mojo-hashlib @ cfccd1e | SHA-256, 64 MiB | 133 ms | 28 ms | Python `hashlib` (OpenSSL, SHA-NI) | **0.21x** |
| | SHA-1, 64 MiB | 59 ms | 26 ms | same | **0.44x** |
| | MD5, 64 MiB | 71 ms | 60 ms | same | **0.85x** |
| | 200 k short messages | 134 ms | 268 ms | same | 2.0x |
| | 100 k shlex round trips | 46 ms | 1272 ms | Python `shlex` | 28x |
| mojo-glob @ 2b2f2ca | `*.py`, compiled Pattern | 12.8 ns | 147 ns | `fnmatch.fnmatchcase` | 11x |
| | `src/module_1*/*_[0-4]?.txt`, Pattern / per call | 62 / 1057 ns | 159 ns | same (caches compiled regex) | 2.6x / **0.15x** |
| mojo-args @ 0c838ba | 200 k argv parses | 192 ms | 2844 ms | `argparse` | 15x |
| mojo-pyformat @ f6d6cdb | 1 M values `.2f` / `g` / `.3e` | 33 / 121 / 123 ms | 191 / 186 / 208 ms | `format()` | 5.8x / 1.5x / 1.7x |
| mojo-semver @ 0418c69 | parse / compare | 35 / 8.5 ns | 1266 / 465 ns | `semver` package | 36x / 55x |
| mojo-prometheus @ 8d561cf | counter inc / histogram observe | 5.8 / 20 ns | 204 / 518 ns | `prometheus_client` | 35x / 26x |
| | exposition, 1000 children | 8.8 ms | 57 ms | same | 6.5x |
| mojo-inotify @ 50959a7 | drain 200 k events | 32 ms | 95 ms | Python ctypes + struct | 3.0x |
| mojo-subprocess @ 858d2ad | spawn `true` | 339 us | 410 us | `subprocess.run` | 1.2x |
| | pipe 256 MiB through `cat` | 1.06 GB/s | 0.68 GB/s | same | 1.6x |
| mojo-amdgpu @ 801090c | one sample of all metrics | 16.5 us | 29.6 us | Python `os.pread` + parse | 1.8x |
| | open card | 739 us | 227 us | same | **0.31x** |
| mojo-uregex @ f359536 | tokenizer pre-split, GPT-2 / Llama 3 patterns | 24 / 25 MB/s | 13 / 16 MB/s | `regex` 2026.9.29 | 1.9x / 1.6x |

uregex ran once (its `tools/bench.sh` has no rounds); every other row is the median of 3.

Third batch, harnesses added today in each library (same session and conditions; gpu-waitd left running for vattn):

| Library @ commit | Job | Mojo | Reference | Reference is | Ratio |
|---|---|---|---|---|---|
| mojo-gguf @ 5e751ba | `quantize --pure` Qwen2.5-0.5B bf16 to Q8_0 | 0.85 s, 48 MB | 0.86 s, 964 MB | `llama-quantize --pure` at pin 1744c6bde, both default threads | 1.0x, 20x less memory |
| | to Q4_0 | 0.54 s | 0.68 s | same | 1.3x |
| | to Q4_K | 0.71 s | 1.16 s | same | 1.6x |
| mojo-xxhash @ e5e9a76 | XXH3-64 / XXH64 / XXH32, 64 MiB | 67.4 / 25.5 / 13.0 GB/s | 26.1 / 14.6 / 10.0 GB/s | system libxxhash 0.8.4 (generic x86-64 build), same process | 2.6x / 1.7x / 1.3x |
| mojo-toml @ 88c47e3 | parse 3.1 MB | 100 ms | 525 ms | `tomllib` | 5.3x |
| mojo-mmap @ b312133 | sum 256 MiB through the mapping | 31.5 GB/s | 4.2 GB/s | Python `mmap` + numpy sum | 7.5x |
| | same through `read()` into a buffer | 1.49 GB/s | 1.71 GB/s | Python `read()` + numpy | **0.87x** |
| mojo-systemd @ fc10dc8 | `notify()`, 100 k datagrams | 4.9 us | 5.6 us | Python `socket`, open/send/close per call | 1.1x |
| mojo-proptest @ 7fd625c | generate one case, `Lists(Ints(-1000, 1000))` | 0.095 us | 357 us | Hypothesis | ~3700x * |
| | shrink a planted failure | 0.038 ms | 57.5 ms | same | * |

gguf: every round checks the two output files are byte-identical before its time counts. xxhash 16 B / 200 B rows
(2.0 / 9.5 ns) are left out: the C side goes through `OwnedDLHandle.call`, which looks the symbol up on every call,
so the C number there is lookup overhead. proptest \*: Hypothesis does much more per case (coverage feedback, example
database machinery even when disabled) and shrinks better: it reaches `[1000]` where mproptest stops at
`[206, 794]`. The ratio measures that difference in design, not the same work done faster.

mojo-imkit @ 1330708 (immediate-mode GUI, no fair reference): 21.0 us CPU per demo frame of 150 draw commands
(`tools/uibench`, minimum of 40 rounds of 300 frames).

mojo-vattn @ 356f61b: **void**. Parity passed 3/3 (real Wan shape, max error equal to SDPA's), but the SDPA arm ran
1.74 to 2.03 s per call against the preregistered 0.80 to 0.95 s, and spread per arm exceeded 10 %; by
`bench/prereg-S3.md` that means the bench does not reproduce the reference call, so no ratio is quoted. The two arms
were within 5 % of each other (vattn 2.05 s, SDPA 1.95 s, medians). The README already states the kernel is not
faster than SDPA.

mojo-cv @ 0b851fb, fresh run of its own harness (`tests/run.sh --bench-all`, best of 5 per op, all threads, against
cv2 5.0): 47 of 63 1080p rows faster than cv2, 4 more within 1.5x, 12 slower (canny, HSV/Lab/Luv/swap colour
conversions, flip_x, gmm, thresh_bin, tophat, transpose, rim). Full table: `bench-receipts/2026-11-10/mojo-cv-table.md`.

mojo-bento @ 8dd3b3c (HTTP service framework, no reference run): 2.39 M req/s GET with 8 connections and
pipeline 16; 370 k req/s POST with 4 workers; 223 k SSE events/s to one client. The clients are Python, so these are
lower bounds.

\* Small job: the reference's import and object setup dominate. This is the cost of one small read, not throughput.

\** These bind the system C library (libz, libzstd, liblz4), the same one the Python module uses. The rows show the
binding adds no overhead (gzip is 10% slower); they are not Mojo codec speed. Pure-Mojo codecs are in progress.

Baselines ran at their defaults: `tokenizers` single thread (its batch API is parallel and would be faster), no
tuning of any reference. Where a reference has a faster configuration, the ratio would shrink.

Bold ratios are losses. 35 of the 36 indexed entries appear above; the 36th, mojo-lib-audit, is a checking tool,
not a library. mojo-struct is benchmarked but not yet in the index.

Falsifier: rerun on the same commits. A ratio more than 20% off the table, on a quiet x86-64 box, means this page is
wrong. Rerun: `scripts/bench-all.sh` (all) or `scripts/bench-all.sh mojo-uuid` (one); base64 and struct take the
built binary as argument (`scripts/bench.sh .work/bench-after .work/bench-after`).
