# API

`from semver import Version, parse, is_valid, compare`

| Call | Does |
|---|---|
| `parse(s) -> Version` | Strict `major.minor.patch[-pre][+build]`; raises `"<s> is not valid SemVer string"`. |
| `is_valid(s) -> Bool` | `parse` without raising. |
| `compare(a, b) -> Int` | Parse both, then `-1`, `0` or `1`. |
| `Version(major, minor, patch, prerelease, build)` | Fields; an empty `prerelease`/`build` means absent. This constructor does not validate (negative numbers, bad identifiers pass): build versions from text with `parse`. |
| `v.compare(o)`, `==`, `!=`, `<`, `<=`, `>`, `>=` | SemVer precedence; build metadata ignored. |
| `v.match(expr)` | `<`, `>`, `<=`, `>=`, `==`, `!=` then a version; a bare version means `==`; anything else raises. |
| `v.bump_major()`, `bump_minor()`, `bump_patch()` | Next version, prerelease and build dropped. |
| `v.bump_prerelease(token="rc")` | Increment the last number in the prerelease, or start `<token>.1` (`token=""` gives `1`). Build dropped. |
| `v.bump_build(token="build")` | Same for build; prerelease kept. |
| `v.finalize_version()` | Drop prerelease and build. |
| `String(v)` / `print(v)` | `1.2.3-rc.1+build.5` (via `Writable`). |
