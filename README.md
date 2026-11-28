# mojo-libs

[![ci](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml)
[![Used by](https://mojourney.dev/badge/amarbaro/mojo-libs/used-by.svg)](https://mojourney.dev/repos/amarbaro/mojo-libs#used-by)
[![Mojo version](https://mojourney.dev/badge/amarbaro/mojo-libs/mojo.svg)](https://mojourney.dev/repos/amarbaro/mojo-libs)

The amarbaro Mojo libraries in one repository, one folder per library under `libs/<name>/`. Each keeps its own package,
import name, version, `recipe.yaml`, tests against an oracle, `docs/api.md`, `docs/design.md` and an agent skill in `skills/`.
A library reaches another as the sibling folder `../<name>` (`deps.tsv` lists who uses whom); `scripts/ci-all.sh` runs every
library's `scripts/ci.sh`. A tag `<name>-v<version>` publishes that one library's conda package ([docs/monorepo.md](docs/monorepo.md)).

## Install

Every library is a conda package on [prefix.dev/amarbaro/amarbaro](https://prefix.dev/channels/amarbaro/amarbaro), named `mojo-<name>` (xmojo too: `mojo-xmojo`); the import name is in each README.

```
pixi init app && cd app
pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro
pixi add mojo-json
```

Toolchains: Mojo 1.2 stable; the weekly matrix also builds every library on the current nightly, and reports the ones whose `scripts/ci.sh` cannot select one (xmojo pins 1.2.0).

<!-- libs -->
| library | what | version | toolchain | our deps |
|---|---|---|---|---|
| [mojo-aio](libs/aio/) | epoll event loop for Mojo: readiness events, timers, non-blocking TCP | 0.1.1 | `mojo>=1.2.0,<1.3` | - |
| [mojo-amdgpu](libs/amdgpu/) | AMD GPU telemetry for Mojo from sysfs and hwmon, no ROCm needed: VRAM, busy, power, temperature, clocks, KFD holders | 0.1.5 | `mojo>=1.2.0,<1.3` | - |
| [mojo-args](libs/args/) | Command-line parsing for Mojo with Python argparse behaviour: subcommands, typed flags, --help | 0.1.4 | `mojo>=1.2.0,<1.3` | - |
| [mojo-base64](libs/base64/) | Base16/32/64 encode/decode matching CPython base64 | 0.1.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-bench](libs/bench/) | Benchmark harness for Mojo with statistics: warmup, auto iteration count, median, MAD, p95, seeded bootstrap CI, compare | 0.1.1 | `mojo>=1.2.0,<1.3` | - |
| [mojo-bento](libs/bento/) | BentoML's serving core as a Mojo library: an HTTP/1.1 server and typed JSON endpoints that answer like BentoML 1.4 | 0.1.3 | `mojo>=1.2.0,<1.3` | mojo-aio, mojo-gguf-core, mojo-json, mojo-posix, mojo-safetensors, mojo-systemd |
| [mojo-csv](libs/csv/) | CSV reader/writer with CPython csv parity | 0.1.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-cv](libs/cv/) | Computer vision for Mojo: OpenCV-style 2D ops, calibration, 3D geometry and CAD export, each checked against cv2 5.0 or an exact oracle | 0.1.5 | `max==26.7.0` | - |
| [mojo-gguf](libs/gguf/) | GGUF tooling in Mojo, byte-identical with llama.cpp's converters, quantizer and gguf-py scripts | 0.2.1 | `mojo>=1.2.0,<1.3` | mojo-uregex |
| [mojo-gguf-core](libs/gguf-core/) | Read (mmapped, zero copy) and write GGUF files from Mojo, as gguf-py does | 0.1.5 | `mojo>=1.2.0,<1.3` | - |
| [mojo-glob](libs/glob/) | Shell-style wildcards for Mojo: fnmatch and glob (recursive **, root_dir), identical to Python | 0.1.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-gzip](libs/gzip/) | gzip, zlib and raw deflate for Mojo through the system libz, plus crc32 and adler32 | 0.1.4 | `mojo>=1.2.0,<1.3` | - |
| [mojo-hashlib](libs/hashlib/) | Hashing and shell quoting for Mojo, byte-identical with Python hashlib and shlex | 0.1.4 | `mojo>=1.2.0,<1.3` | - |
| [mojo-imkit](libs/imkit/) | Immediate-mode GUI for Mojo, composed on the GPU: SDL3 window, FreeType text, widgets as one draw list | 0.11.0 | `max==26.7.0` | - |
| [mojo-inotify](libs/inotify/) | Watch files and directories from Mojo with Linux inotify, pollable | 0.1.5 | `mojo>=1.2.0,<1.3` | - |
| [mojo-json](libs/json/) | JSON for Mojo, byte-identical with Python json | 0.1.4 | `mojo>=1.2.0,<1.3` | - |
| [mojo-log](libs/log/) | Structured logging for Mojo: levels, key=value fields, text and JSON-lines, stderr/file/journald sinks | 0.1.1 | `mojo>=1.2.0,<1.3` | - |
| [mojo-mmap](libs/mmap/) | Memory-mapped files for Mojo: zero-copy Span views, read and write, madvise, msync | 0.1.3 | `mojo>=1.2.0,<1.3` | - |
| [mojo-msgpack](libs/msgpack/) | MessagePack encode and decode for Mojo, pure Mojo, zero-copy str and bin views | 0.1.1 | `mojo>=1.2.0,<1.3` | - |
| [mojo-posix](libs/posix/) | POSIX processes, signals and sockets for Mojo: spawn with cwd/env/pgid, signalfd, poll; posix.subprocess (subprocess.run) and posix.systemd (sd_notify) | 0.1.7 | `mojo>=1.2.0,<1.3` | - |
| [mojo-prometheus](libs/prometheus/) | Prometheus metrics for Mojo: counters, gauges, histograms, summaries with labels, text exposition byte-identical with prometheus_client | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-pyformat >=0.2.0,<0.3 |
| [mojo-proptest](libs/proptest/) | Property tests for Mojo: seeded generators, shrinking, a failure that names the seed and the minimal case | 0.2.0 | `mojo>=1.2.0,<1.3` | - |
| [mojo-pyformat](libs/pyformat/) | Python-exact number formatting for Mojo: {:.Nf}, {:,}, {:g}, {:%}, rounding on the exact binary value | 0.2.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-safetensors](libs/safetensors/) | Read (mmapped, zero copy) and write safetensors files from Mojo, as the reference does | 0.1.5 | `mojo>=1.2.0,<1.3` | mojo-json |
| [mojo-semver](libs/semver/) | Semantic Versioning 2.0 for Mojo: parse, precedence, bump, match, identical to Python semver | 0.1.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-sqlite](libs/sqlite/) | SQLite bindings for Mojo, measured against Python sqlite3 | 0.1.5 | `mojo>=1.2.0,<1.3` | - |
| [mojo-struct](libs/struct/) | Pack and unpack binary data like CPython struct | 0.1.0 | `mojo>=1.2.0,<1.3` | - |
| [mojo-subprocess](libs/subprocess/) | Forwarding package: `import subprocess` re-exports posix.subprocess (subprocess.run with Python results) from mojo-posix | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-posix >=0.1.7,<0.2 |
| [mojo-systemd](libs/systemd/) | Forwarding package: `import systemd` re-exports posix.systemd (sd_notify READY, STATUS, WATCHDOG, STOPPING) from mojo-posix | 0.1.4 | `mojo>=1.2.0,<1.3` | mojo-posix >=0.1.7,<0.2 |
| [mojo-tls](libs/tls/) | TLS 1.3 and 1.2 client and server for Mojo, with X.509, in pure Mojo: no OpenSSL, no C library | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-aio |
| [mojo-tokenizers](libs/tokenizers/) | Hugging Face tokenizer.json runtime for Mojo: byte-level BPE (GPT-2, Llama 3, Qwen) | 0.1.1 | `mojo>=1.2.0,<1.3` | mojo-json, mojo-uregex |
| [mojo-toml](libs/toml/) | TOML 1.1 parser for Mojo, passes the full toml-test suite | 0.2.4 | `mojo>=1.2.0,<1.3` | - |
| [mojo-uregex](libs/uregex/) | Unicode-aware backtracking regex engine for Mojo: \p{L} classes, lookahead, case-insensitive groups, PCRE alternation semantics, built for LLM tokenizers | 0.3.3 | `mojo==1.2.0` | - |
| [mojo-uuid](libs/uuid/) | RFC UUID values, parsing, formatting and generation for Mojo | 0.1.2 | `mojo>=1.2.0,<1.3` | mojo-hashlib >=0.1.2,<0.2 |
| [mojo-vattn](libs/vattn/) | Flash-attention forward for video DiT self-attention in Mojo, gfx1100 | 0.1.4 | `max==26.7.0` | - |
| [xmojo](libs/xmojo/) | XML for Mojo: parse into structs, stream records, write back, checked against expat | 0.2.2 | `mojo==1.2.0` | - |
| [mojo-xxhash](libs/xxhash/) | xxHash for Mojo: XXH32, XXH64, XXH3-64 and XXH3-128 with seeds and streaming, pure Mojo, identical to the reference | 0.1.2 | `mojo>=1.2.0,<1.3` | - |
| [mojo-zip](libs/zip/) | zipfile read/write for Mojo, pure Mojo: stored + deflate (zlib port), zip64, CRC, CPython zipfile behaviour | 0.1.0 | `mojo>=1.2.0,<1.3` | - |
| [mojo-zstd](libs/zstd/) | zstd and lz4 frame compression for Mojo, pure Mojo with no C library | 0.2.0 | `mojo>=1.2.0,<1.3` | - |
<!-- /libs -->

Merged libraries: `mojo-subprocess` and `mojo-systemd` live on in mojo-posix as `posix.subprocess` and `posix.systemd`; their packages
only forward so old imports keep working. The supervision code (detection, annotators, metrics, datasets) is now part of
[mojo-cv](libs/cv/) under `src/supervision`; the `mojo-supervision` 0.1.x packages on the channel come from the old repo.

Tools (command-line programs, not libraries): [mojo-ablate](https://github.com/amarbaro/mojo-ablate), behavior steering for local models in Mojo: directions, rank-1 edit, TPE, BF16 bake.

The table is generated from each library's `pyproject.toml` by `tools/gen.mojo`; `scripts/check.sh`
fails when it is stale, and `scripts/check.sh --write` refreshes it. Toolchain is the pin the
library builds with; "our deps" are other libraries from this table.

Every library follows one checklist from plan to publish: file layout, memory-capped builds,
docs and skill, stable and nightly Mojo, review. Its mechanical half is `mojo-lib-audit`.

## License

Apache-2.0, see `LICENSE`.
