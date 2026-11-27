---
name: mojo-systemd
description: "sd_notify from Mojo: ready, status, watchdog, stopping, watchdog_usec. Use when a Mojo service runs under systemd as Type=notify or with WatchdogSec."
---

# mojo-systemd

## Install

Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-systemd`. From source: `git clone https://github.com/amarbaro/mojo-libs.git && cd mojo-libs/libs/systemd`, then `mojo run -I src -I ../posix/src app.mojo`.

## Use

Calls return False outside systemd, so no guard is needed.

```mojo
from systemd import ready, watchdog, watchdog_usec


def main() raises:
    _ = ready("serving")
    # loop: ping every watchdog_usec()/2 microseconds
    _ = watchdog()
    print(watchdog_usec())
```

Unit: `Type=notify`, optional `WatchdogSec=N`. Check: `scripts/check.sh` ends `PASS all`.
