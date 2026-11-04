# Design

- **Python semver as the specification**, quirks included: prerelease parts compare numbers as numbers and before text; `bump_prerelease` increments the last digit run with Python's own slicing (`rc.9` becomes `rc.10`).
- **No regex.** The parser splits at the first `-` before any `+`, then checks each identifier by hand: 0 or a number without a leading zero for the core and numeric prerelease parts, `[0-9A-Za-z-]+` for the rest. That is the same grammar as Python semver's regex.
- **Compare without converting.** Numeric prerelease parts never have leading zeros, so a longer digit run is larger and equal lengths compare as text: no integer parse, no overflow on long parts.
- **Struct:** three `Int`s and two `String`s; empty means absent, which the grammar allows because an empty prerelease or build is invalid anyway.
- Derives `Writable`; `==` is precedence equality (build ignored), as in Python.
