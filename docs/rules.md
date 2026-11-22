# Rules (what broke -> rule)

- A pinned fetch of a sibling library became the sibling at HEAD, and json, msgpack and toml lost their prop smoke step because proptest 0.2
  imports `mproptest` -> a library that stops fetching a pinned dependency runs its gate against the sibling before the change is committed.
- gguf's gates took `git rev-parse --show-toplevel` for the library root, which is the repository root here -> a script finds its root from its own
  path (`dirname "$0"`), never from git.
- subprocess carried a vendored `src/posix` older than `libs/posix` (no `spawn_pair`, a 107 byte `sun_path` limit) -> a library does not vendor
  a sibling; it includes `../<name>/src`.
- `uv sync` in a library rewrites its `uv.lock` -> CI runs inside a clone and a local run restores the lock files before committing.
- args and zip went red on ubuntu-26.04: `uv python find 3.14` and `uv sync` took the system CPython 3.14.4, whose argparse and zipfile
  output differ from 3.14.10 -> an oracle Python is pinned to the exact patch (`uv python find 3.14.10`, `.python-version`), never a minor.
- A before/after check of a cv fix ran the same binary twice: `tests/supervision/build_all.sh` skips a binary that exists -> delete
  `build/<stem>` (or check its mtime) before calling a rebuild a proof.
- cv's yolo split went red on GitHub only: supervision lists images in readdir order, and ext4 orders by a per-fs hash
  -> a port and its oracle list a directory sorted (Mojo `sort`, oracle patched in gen_datasets.py), never readdir order.
- A readdir A/B on a 3-image fixture passed by chance -> an order test uses a fixture large enough that a different
  order changes the result (s3: 11 images), and clears driver output dirs (build/ds-out) between runs.
- 15 ci.sh ran `uv sync` only when MOJO was unset; on the nightly matrix the oracle died, check.sh counted 0 scenarios
  and printed PASS, every mutant survived -> setup that a gate needs runs on every toolchain path, and a gate that
  counts its cases fails on zero (a skip is never a pass).
- A test client wrote 4 MiB before reading against a server that pauses reads at max_out; it passed wherever kernel
  buffers held the backlog -> bound a test peer's in-flight bytes to what the protocol guarantees, and reproduce
  buffer-size flakes in `unshare -rn` with small tcp_rmem/tcp_wmem.
- aio timers asserted a 2 ms worst-case lateness on a shared runner -> a timing gate on CI asserts order and a
  median, plus a generous cap; one preemption must not decide it.
- Mojo 1.3 nightly -O3 drops digits from an append-`u % 10`-then-reverse loop over UInt64 (log `_int`); -O0 and 1.2
  are correct -> integer-to-text fills a pre-sized buffer from the back; a nightly-only output diff gets an -O0/-O3
  A/B before any oracle theory.
- `gpu-wait run` does not pass the caller's environment: a nightly run as `MOJO=... gpu-wait run -- ci.sh` silently
  used the stable pin and "passed" (imkit, vattn) -> pass toolchain overrides with `--env MOJO=...`, and check the log
  names the toolchain under test before counting a result.
