# mojo-subprocess

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml) [![license](https://img.shields.io/github/license/amarbaro/mojo-libs)](https://github.com/amarbaro/mojo-libs/blob/main/LICENSE) [![conda](https://img.shields.io/badge/conda-mojo--subprocess-9DAE51)](https://prefix.dev/channels/@amarbaro/amarbaro/packages/mojo-subprocess)
<!-- /badges -->

Python's `subprocess.run` for Mojo: run a program, capture stdout and stderr, feed it input, with timeout, cwd, env and check. Large outputs on both pipes are drained together, so nothing deadlocks. The code lives in mojo-posix as `posix.subprocess`; `import subprocess` is a forwarding module over it, so mojo-posix is a dependency.

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-subprocess`. From source: `git clone https://github.com/amarbaro/mojo-libs.git && cd mojo-libs/libs/subprocess`, then `mojo run -I src -I ../posix/src app.mojo`.
Toolchains: Mojo 1.2.0 stable, in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix.
<!-- /install -->

```mojo
from subprocess import run


def main() raises:
    var r = run(["git", "rev-parse", "HEAD"], timeout=5.0)
    if r.returncode == 0:
        print(r.text())  # stdout as text; r.stdout / r.stderr are bytes
    var cat = run(["sort"], input="b\na\n".as_bytes())
    print(cat.text(), end="")
```

| Call | Result |
|---|---|
| `run(argv, input, capture_output, timeout, cwd, env, check, close_stdin, capture_stderr)` | `CompletedProcess` |
| `check_output(argv, timeout, cwd, env)` | stdout bytes; raises on a non-zero exit |
| `CompletedProcess.args`, `.returncode`, `.stdout`, `.stderr`, `.text()` | argv, exit code (minus the signal number), captured bytes, stdout as text |

Defaults and error texts are in [docs/api.md](docs/api.md).

**Checked against Python subprocess:** exit codes and signal deaths (`-9`, `-15`, `-2`), a 3 MB + 3 MB flood on stdout and stderr at once, a 5 MB stdin echo, a child that exits without reading its input, `head` closing early, cwd and env, argv with spaces, empty strings and Unicode, empty input (EOF), stdout and stderr byte-identical; timeout, missing program, empty argv, `check` and `check_output` raise where Python raises, with the same return codes (the error texts are this library's own, see docs/api.md). `scripts/check.sh`, each scenario twice. 6 of 6 mutants caught. Builds and passes on Mojo 1.2.0 and the 1.3 nightly.

**Speed** (7800X3D, load average about 29 at the time): `run(["true"])` 418 µs and 0.60 GB/s through `cat`; Python 543 to 1,155 µs and 0.35 to 0.47 GB/s across runs.

**Limits:** Linux only. It needs Linux 5.3 or newer for the pidfd (older kernels fall back to polling `waitpid` every millisecond) and glibc 2.29 or newer (`posix_spawn_file_actions_addchdir_np`). The program is looked up on this process's PATH, also when `env` sets another PATH (Python uses the PATH from `env`); pass an absolute path in that case.

- API: [docs/api.md](docs/api.md) · design: [docs/design.md](docs/design.md) · agent skill: [skills/mojo-subprocess/SKILL.md](skills/mojo-subprocess/SKILL.md)
- License: Apache-2.0
