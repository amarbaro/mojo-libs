# Design

- **Python semver as the specification**, quirks included: prerelease parts compare numbers as numbers and before text; `bump_prerelease` increments the last digit run with Python's own slicing (`rc.9` becomes `rc.10`).
- **No regex, one scan.** The parser walks the bytes once (core numbers, then prerelease to the first `+`, then build) and checks each identifier in place: 0 or a number without a leading zero for the core and numeric prerelease parts, `[0-9A-Za-z-]+` for the rest. That is Python semver's regex grammar for ASCII input; Python's `\\d` also matches Unicode decimal digits, which this parser refuses (documented limit). One trailing newline is dropped first, as Python's `$` allows.
- **Compare without allocating or converting.** Prerelease parts are compared in place by index, no split. Numeric prerelease parts never have leading zeros, so a longer digit run is larger and equal lengths compare as text: no integer parse, no overflow on long parts.
- **Struct:** three `Int`s and two `String`s; empty means absent, which the grammar allows because an empty prerelease or build is invalid anyway.
- Derives `Writable`; `==` is precedence equality (build ignored), as in Python.
