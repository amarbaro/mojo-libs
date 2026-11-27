# Design

- **One poll loop** over the stdout and stderr read ends, the stdin write end (non-blocking) and a **pidfd** for the child. Reads and writes interleave, so a child that fills one pipe while we feed another cannot deadlock it; the pidfd tells exactly when the child exits, with no sleeping and with the timeout still enforced.
- **posix_spawnp**, not fork: the pipes are `pipe2(O_CLOEXEC)`, dup2'd onto 0/1/2 by spawn file actions, so no stray descriptor leaks into the child. Signal mask and handlers are reset in the child.
- **64 KiB chunks** into one reusable buffer appended to the output lists: no per-read allocation.
- Return codes come from mojo-posix `reap` (minus the signal number, as `Popen.returncode`).
- The code is `posix.subprocess` in mojo-posix, next to the primitives it uses (`reap`, `kill`, `PollSet`, the argv/envp builder); `src/subprocess` only forwards. The sibling library `../posix` in this monorepo (`-I ../posix/src`) is a dependency of the conda package.
