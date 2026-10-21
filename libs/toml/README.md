# mojo-toml

A TOML 1.1 parser for Mojo that passes the whole official conformance suite:
[toml-test](https://github.com/toml-lang/toml-test) v2.2.0 `-toml 1.1`, 214/214 valid
and 467/467 invalid, on Mojo 1.1.0 and 1.2 nightly.

## It was never abandoned, only untested

A Sonnet lane wrote it on 2026-09-19 and it was shelved before any test ran. When it
was first run against toml-test on 2026-10-21 it passed all of TOML 1.0 unchanged.
TOML 1.1 needed four additions: optional seconds, the `\e` and `\xHH` escapes, and
newlines and trailing commas in inline tables.

Because those additions are accepted, 9 of the TOML 1.0 "invalid" tests now parse.
Every valid 1.0 document parses as before.

## Use

```mojo
from toml import parse
```

`tests/decoder.mojo` is the toml-test decoder (TOML on stdin, tagged JSON on stdout),
and the conformance check:

```
mojo build -I src tests/decoder.mojo -o decoder
toml-test test -toml 1.1 -decoder ./decoder
```
