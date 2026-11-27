# mojo-systemd

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml) [![license](https://img.shields.io/github/license/amarbaro/mojo-libs)](https://github.com/amarbaro/mojo-libs/blob/main/LICENSE) [![conda](https://img.shields.io/badge/conda-mojo--systemd-9DAE51)](https://prefix.dev/channels/@amarbaro/amarbaro/packages/mojo-systemd)
<!-- /badges -->

Tell systemd from Mojo that a service is ready, what it is doing, and that it is still alive
(the sd_notify protocol). Libc only, no libsystemd. The datagrams are checked byte for
byte against a Python sender, and a real `Type=notify` unit with `WatchdogSec` proves the
watchdog stays quiet while pings flow and kills the service when they stop. The code lives in
mojo-posix as `posix.systemd`; `import systemd` is a forwarding module over it.

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-systemd`. From source: `git clone https://github.com/amarbaro/mojo-libs.git && cd mojo-libs/libs/systemd`, then `mojo run -I src -I ../posix/src app.mojo`.
Toolchains: Mojo 1.2.0 stable, in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix.
<!-- /install -->

```mojo
from systemd import ready, status, watchdog, watchdog_usec


def main() raises:
    # Under a Type=notify unit these reach systemd; without NOTIFY_SOCKET each returns False and nothing is sent.
    print(ready("serving"), status("3 jobs queued"), watchdog(), watchdog_usec())
```

**Limits:** Linux only. It sends notification states and nothing else: no file descriptor passing,
no `sd_listen_fds`, no journal logging.

## What you get

| Call | Sends |
|---|---|
| `notify(state)` | any sd_notify state string, for example `"READY=1\nMAINPID=42"` |
| `ready(msg="")` | `READY=1`, plus `STATUS=msg` when set |
| `status(msg)` | `STATUS=msg` |
| `watchdog()` | `WATCHDOG=1` |
| `stopping()` | `STOPPING=1` |
| `reloading()` | `RELOADING=1` with the `MONOTONIC_USEC` systemd 253+ expects |
| `watchdog_usec()` | nothing: the interval from `$WATCHDOG_USEC`, 0 when off or when `$WATCHDOG_PID` names another process |

- Every send call returns `False` outside systemd (`$NOTIFY_SOCKET` unset), so the same binary runs
  from a shell. A set but unusable socket raises `systemd: ...`.
- Path and abstract (`@name`) sockets.

API: [docs/api.md](docs/api.md). Design: [docs/design.md](docs/design.md).

## Checks

| Script | What |
|---|---|
| `scripts/check.sh` | 8 calls under 7 socket/env setups, datagrams identical to `tools/oracle.py`; then a real user unit, `Type=notify`, `WatchdogSec=1`: pinging stays active, silent gets killed with `Result=watchdog` |
| `scripts/selfcheck.sh` | 4 mutants (abstract socket, WATCHDOG_PID, dropped byte, no pings) all rejected |
| `scripts/ci.sh` | install and gate, same on GitHub and a local VM; without a user service manager the unit part prints `SKIP` and the last line says so |

## License

Apache-2.0.
