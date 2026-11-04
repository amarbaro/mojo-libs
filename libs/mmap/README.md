# mojo-mmap

<!-- badges -->
<!-- /badges -->

Memory-mapped files for Mojo. A file becomes one zero-copy `Span[UInt8]`, read-only or shared and writable, with `madvise` and `msync`. 70 lines, Linux, no dependencies beyond libc.

```mojo
from mmap import MappedFile, create, SEQUENTIAL

var w = create("data.bin", 1 << 20)      # sized, zero-filled, writable
var b = w.mut_bytes()
b[0] = 42
w.flush()                                # msync: durable on disk

var m = MappedFile("data.bin")           # read-only
m.advise(SEQUENTIAL)
print(len(m), m.bytes()[0])              # no copy, no read()
```

**Checked against Python `mmap`:** reads, writes and in-place updates over 1 B to 1 MiB (page edges included), and the empty-file and missing-file errors, each scenario twice (`scripts/check.sh`). 3 of 3 mutants caught (`scripts/mutants.sh`). Builds and passes on Mojo 1.2.0 and the 1.3 nightly.

**Speed** (256 MiB file, warm page cache, 7800X3D): 24.9 GB/s summing through the mapping, against 1.2 GB/s for `read_bytes()` into a buffer (`tests/bench.mojo`).

**Requires** Mojo 1.2 on Linux (x86-64 or aarch64 glibc).

- API: [docs/api.md](docs/api.md) · design: [docs/design.md](docs/design.md) · agent skill: [skills/mojo-mmap/SKILL.md](skills/mojo-mmap/SKILL.md)
- License: Apache-2.0
