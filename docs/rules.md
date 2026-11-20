# Rules (what broke -> rule)

- A pinned fetch of a sibling library became the sibling at HEAD, and json, msgpack and toml lost their prop smoke step because proptest 0.2
  imports `mproptest` -> a library that stops fetching a pinned dependency runs its gate against the sibling before the change is committed.
- gguf's gates took `git rev-parse --show-toplevel` for the library root, which is the repository root here -> a script finds its root from its own
  path (`dirname "$0"`), never from git.
- subprocess carried a vendored `src/posix` older than `libs/posix` (no `spawn_pair`, a 107 byte `sun_path` limit) -> a library does not vendor
  a sibling; it includes `../<name>/src`.
- `uv sync` in a library rewrites its `uv.lock` -> CI runs inside a clone and a local run restores the lock files before committing.
