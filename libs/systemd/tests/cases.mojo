# Runs a scenario: one call per line ("ready [msg]", "status msg", "watchdog", "stopping",
# "reloading", "notify raw", "usec"); prints each call's result. tools/oracle.py is the same in Python.
from std.sys import argv
from systemd import notify, ready, status, watchdog, stopping, reloading, watchdog_usec


def main() raises:
    for line in open(argv()[1], "r").read().splitlines():
        var cmd = String(line)
        var parts = cmd.split(" ", maxsplit=1)
        var op = String(parts[0])
        var arg = "" if len(parts) < 2 else String(parts[1]).replace("\\n", "\n")
        if op == "usec":
            print("usec", watchdog_usec())
            continue
        try:
            var ok: Bool
            if op == "ready":
                ok = ready(arg)
            elif op == "status":
                ok = status(arg)
            elif op == "watchdog":
                ok = watchdog()
            elif op == "stopping":
                ok = stopping()
            elif op == "reloading":
                ok = reloading()
            else:
                ok = notify(arg)
            print(op, "sent" if ok else "unset")
        except e:
            print(op, "error")
