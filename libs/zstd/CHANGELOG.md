# Changelog

Newest first.

- Unreleased: level-3 speed (issue #31): compress 0.76 to 0.96x libzstd's MB/s, decompress 0.64 to 0.70x on five inputs
  (the issue measured 1.3 to 6.8x and 1.6 to 4.6x slower); same output sizes; `scripts/bench31.sh` throughput harness

- [v0.2.0](docs/releases/v0.2.0.md) (2026-11-10): native zstd and lz4 in Mojo, no C library

- [v0.1.1](docs/releases/v0.1.1.md) (2026-11-08): packaging: compiler pin to build minor
- [v0.1.0](docs/releases/v0.1.0.md) (2026-11-04): zstd and lz4 frames for Mojo, one-shot and streaming zstd
