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
