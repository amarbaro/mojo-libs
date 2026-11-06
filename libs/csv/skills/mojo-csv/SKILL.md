---
name: mojo-csv
description: CSV reader/writer with CPython csv parity
---

# mojo-csv

Install with -I src. Use read_all and write_all. Gate command: scripts/check.sh.

Gotchas: bytes input, invalid UTF-8 passthrough, quoting constants.
## Usage

Call read_all with bytes. Inspect CsvField.is_null.

## Install

Use -I src from a clone. Gate: scripts/check.sh.

## Gotchas

Invalid UTF-8 passes through. Quoting constants match CPython.
