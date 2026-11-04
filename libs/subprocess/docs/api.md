# API

`from subprocess import run, check_output, CompletedProcess`

| Call | Does |
|---|---|
| `run(argv, input=Span(), capture_output=True, timeout=-1.0, cwd="", env=[], check=False) -> CompletedProcess` | Runs `argv[0]` (searched on PATH). `input` goes to stdin (otherwise stdin is inherited). `timeout` in seconds kills the child (SIGKILL) and raises `... timed out after S seconds`. `env` as `NAME=value` replaces the environment; empty inherits. `check=True` raises `... returned non-zero exit status N.` Raises when the program cannot start. |
| `check_output(argv, timeout=-1.0, cwd="", env=[]) -> List[UInt8]` | `run(..., check=True).stdout`. |
| `CompletedProcess.args`, `.returncode`, `.stdout`, `.stderr`, `.text()` | Exit code, or minus the signal number; captured bytes; stdout as UTF-8. |

`run` sets SIGPIPE to ignored in this process, as Python does at startup; children get default handlers back.
