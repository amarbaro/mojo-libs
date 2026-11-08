#!/usr/bin/env bash
# error-line.sh LOG [--key]: the first error line of a failed CI log.
# Pick: the first `error:` line at or after the first `FAIL` line (ci.sh prints FAIL, then the compiler output),
# else the first `error:` line, else the first FAIL line, else the last line. --key strips what differs between
# libraries that hit the same error: file paths, line:col numbers, hex addresses, runs of blanks. Empty log -> "no output".
set -euo pipefail
log=${1:?usage: error-line.sh LOG [--key]}
line=$(awk '
  /^FAIL/ && !f { f = 1; ff = $0 }
  /error:/ && f && !a { a = $0 }
  /error:/ && !e { e = $0 }
  NF { last = $0 }
  END { print (a != "" ? a : e != "" ? e : ff != "" ? ff : last != "" ? last : "no output") }' "$log")
[ "${2:-}" = --key ] || { printf '%s\n' "$line"; exit 0; }
printf '%s\n' "$line" | sed -E \
  -e 's/^.*(error:)/\1/' \
  -e 's#[^[:space:]'"'"'"(]*/[^[:space:]'"'"'"):]*##g' \
  -e 's/[A-Za-z0-9_.-]+\.(mojo|mojopkg|mojoc|py|sh)\b//g' \
  -e 's/:[0-9]+(:[0-9]+)?//g' \
  -e 's/0x[0-9a-fA-F]+//g' \
  -e 's/[[:space:]]+/ /g; s/ $//'
