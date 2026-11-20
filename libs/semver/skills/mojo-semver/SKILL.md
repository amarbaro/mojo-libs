---
name: mojo-semver
description: "Parse, compare, match and bump Semantic Versioning 2.0 strings in Mojo with mojo-semver (same results as Python semver 3.0). Use for version checks, release tooling, dependency constraints in Mojo."
---

# mojo-semver

```mojo
from semver import parse, is_valid
var v = parse(tag)                 # raises on anything not strict SemVer
if v.match(">=1.2.0") and not v.prerelease: ...
var nxt = v.bump_patch()
```

- `==` ignores build metadata (`1.0.0+a == 1.0.0+b`), like Python.
- Strict: `1.2`, `v1.2.3` and leading zeros raise. Use `is_valid` to filter.
- No `^`/`~` ranges: compose them from two `match` calls.

Gate: `scripts/ci.sh` (Python semver oracle, mutants, api, quickstart).
