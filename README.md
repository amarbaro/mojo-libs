# mojo-libs

Index of the amarbaro Mojo libraries. Each one is its own repository with tests against an oracle,
a CI badge, `docs/api.md`, `docs/design.md` and an agent skill in `skills/`.

<!-- libs -->
| library | what | version | toolchain | our deps | ci |
|---|---|---|---|---|---|
| [mojo-aio](https://github.com/amarbaro/mojo-aio) | epoll event loop for Mojo: readiness events, timers, non-blocking TCP | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-aio/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-amdgpu](https://github.com/amarbaro/mojo-amdgpu) | AMD GPU telemetry for Mojo from sysfs and hwmon, no ROCm needed: VRAM, busy, power, temperature, clocks, KFD holders | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-amdgpu/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-args](https://github.com/amarbaro/mojo-args) | Command-line parsing for Mojo with Python argparse behaviour: subcommands, typed flags, --help | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-args/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-bench](https://github.com/amarbaro/mojo-bench) | Benchmark harness for Mojo with statistics: warmup, auto iteration count, median, MAD, p95, seeded bootstrap CI, compare | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-bench/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-bento](https://github.com/amarbaro/mojo-bento) | BentoML's serving core as a Mojo library: an HTTP/1.1 server and typed JSON endpoints that answer like BentoML 1.4 | 0.1.3 | `mojo>=1.2.0,<1.3` | mojo-aio, mojo-gguf-core, mojo-json, mojo-posix, mojo-safetensors, mojo-systemd | ![ci](https://github.com/amarbaro/mojo-bento/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-cv](https://github.com/amarbaro/mojo-cv) | Computer vision for Mojo: OpenCV-style 2D ops, calibration, 3D geometry and CAD export, each checked against cv2 5.0 or an exact oracle | 0.1.5 | `max==26.7.0` | - | ![ci](https://github.com/amarbaro/mojo-cv/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-gguf-core](https://github.com/amarbaro/mojo-gguf-core) | Read (mmapped, zero copy) and write GGUF files from Mojo, as gguf-py does | 0.1.5 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-gguf-core/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-gguf](https://github.com/amarbaro/mojo-gguf) | GGUF tooling in Mojo, byte-identical with llama.cpp's converters, quantizer and gguf-py scripts | 0.2.1 | `mojo>=1.2.0,<1.3` | mojo-uregex | ![ci](https://github.com/amarbaro/mojo-gguf/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-gzip](https://github.com/amarbaro/mojo-gzip) | gzip, zlib and raw deflate for Mojo through the system libz, plus crc32 and adler32 | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-gzip/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-hashlib](https://github.com/amarbaro/mojo-hashlib) | Hashing and shell quoting for Mojo, byte-identical with Python hashlib and shlex | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-hashlib/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-imkit](https://github.com/amarbaro/mojo-imkit) | Immediate-mode GUI for Mojo, composed on the GPU: SDL3 window, FreeType text, widgets as one draw list | 0.7.2 | `max==26.7.0` | - | ![ci](https://github.com/amarbaro/mojo-imkit/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-inotify](https://github.com/amarbaro/mojo-inotify) | Watch files and directories from Mojo with Linux inotify, pollable | 0.1.5 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-inotify/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-json](https://github.com/amarbaro/mojo-json) | JSON for Mojo, byte-identical with Python json | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-json/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-log](https://github.com/amarbaro/mojo-log) | Structured logging for Mojo: levels, key=value fields, text and JSON-lines, stderr/file/journald sinks | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-log/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-msgpack](https://github.com/amarbaro/mojo-msgpack) | MessagePack encode and decode for Mojo, pure Mojo, zero-copy str and bin views | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-msgpack/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-posix](https://github.com/amarbaro/mojo-posix) | POSIX processes, signals and sockets for Mojo: spawn with cwd/env/pgid, signalfd, poll | 0.1.5 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-posix/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-proptest](https://github.com/amarbaro/mojo-proptest) | Property tests for Mojo: seeded generators, shrinking, a failure that names the seed and the minimal case | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-proptest/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-pyformat](https://github.com/amarbaro/mojo-pyformat) | Python-exact number formatting for Mojo: {:.Nf}, {:,}, {:g}, {:%}, rounding on the exact binary value | 0.2.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-pyformat/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-safetensors](https://github.com/amarbaro/mojo-safetensors) | Read (mmapped, zero copy) and write safetensors files from Mojo, as the reference does | 0.1.5 | `mojo>=1.2.0,<1.3` | mojo-json | ![ci](https://github.com/amarbaro/mojo-safetensors/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-sqlite](https://github.com/amarbaro/mojo-sqlite) | SQLite bindings for Mojo, measured against Python sqlite3 | 0.1.5 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-sqlite/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-systemd](https://github.com/amarbaro/mojo-systemd) | sd_notify for Mojo: READY, STATUS, WATCHDOG, STOPPING to systemd | 0.1.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-systemd/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-tokenizers](https://github.com/amarbaro/mojo-tokenizers) | Hugging Face tokenizer.json runtime for Mojo: byte-level BPE (GPT-2, Llama 3, Qwen) | 0.1.1 | `mojo>=1.2.0,<1.3` | mojo-json, mojo-uregex | ![ci](https://github.com/amarbaro/mojo-tokenizers/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-toml](https://github.com/amarbaro/mojo-toml) | TOML 1.1 parser for Mojo, passes the full toml-test suite | 0.2.4 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-toml/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-uregex](https://github.com/amarbaro/mojo-uregex) | Unicode-aware backtracking regex engine for Mojo: \p{L} classes, lookahead, case-insensitive groups, PCRE alternation semantics, built for LLM tokenizers | 0.3.3 | `mojo==1.2.0` | - | ![ci](https://github.com/amarbaro/mojo-uregex/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-vattn](https://github.com/amarbaro/mojo-vattn) | Flash-attention forward for video DiT self-attention in Mojo, gfx1100 | 0.1.4 | `max==26.7.0` | - | ![ci](https://github.com/amarbaro/mojo-vattn/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-zstd](https://github.com/amarbaro/mojo-zstd) | zstd and lz4 frame compression for Mojo through the system libzstd and liblz4 | 0.1.1 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml/badge.svg?branch=main) |
| [xmojo](https://github.com/amarbaro/xmojo) | XML for Mojo: parse into structs, stream records, write back, checked against expat | 0.2.2 | `mojo==1.2.0` | - | ![ci](https://github.com/amarbaro/xmojo/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-mmap](https://github.com/amarbaro/mojo-mmap) | Memory-mapped files for Mojo: zero-copy Span views, read and write, madvise, msync | 0.1.3 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-mmap/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-semver](https://github.com/amarbaro/mojo-semver) | Semantic Versioning 2.0 for Mojo: parse, precedence, bump, match, identical to Python semver | 0.1.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-semver/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-glob](https://github.com/amarbaro/mojo-glob) | Shell-style wildcards for Mojo: fnmatch and glob (recursive **, root_dir), identical to Python | 0.1.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-glob/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-prometheus](https://github.com/amarbaro/mojo-prometheus) | Prometheus metrics for Mojo: counters, gauges, histograms, summaries with labels, text exposition byte-identical with prometheus_client | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-pyformat >=0.2.0,<0.3 | ![ci](https://github.com/amarbaro/mojo-prometheus/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-subprocess](https://github.com/amarbaro/mojo-subprocess) | subprocess.run for Mojo: capture stdout/stderr, input, timeout, cwd/env, same results as Python | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-posix >=0.1.0,<0.2 | ![ci](https://github.com/amarbaro/mojo-subprocess/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-xxhash](https://github.com/amarbaro/mojo-xxhash) | xxHash for Mojo: XXH32, XXH64, XXH3-64 and XXH3-128 with seeds and streaming, pure Mojo, identical to the reference | 0.1.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-xxhash/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-csv](https://github.com/amarbaro/mojo-csv) | CSV reader/writer with CPython csv parity | 0.1.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-csv/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-uuid](https://github.com/amarbaro/mojo-uuid) | RFC UUID values, parsing, formatting and generation for Mojo | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-hashlib >=0.1.2,<0.2 | ![ci](https://github.com/amarbaro/mojo-uuid/actions/workflows/ci.yml/badge.svg?branch=main) |
| [mojo-base64](https://github.com/amarbaro/mojo-base64) | Base16/32/64 encode/decode matching CPython base64 | 0.1.2 | `mojo>=1.2.0,<1.3` | - | ![ci](https://github.com/amarbaro/mojo-base64/actions/workflows/ci.yml/badge.svg?branch=main) |
<!-- /libs -->

The table is generated from each library's `pyproject.toml` by `tools/gen.mojo`; `scripts/check.sh`
fails when it is stale, and `scripts/check.sh --write` refreshes it. Toolchain is the pin the
library builds with; "our deps" are other libraries from this table.

Every library follows one checklist from plan to publish: file layout, memory-capped builds,
docs and skill, stable and nightly Mojo, review. Its mechanical half is `mojo-lib-audit`.

## License

Apache-2.0, see `LICENSE`.
