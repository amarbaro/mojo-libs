# mojo-prometheus

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-libs/actions/workflows/ci.yml) [![license](https://img.shields.io/github/license/amarbaro/mojo-libs)](https://github.com/amarbaro/mojo-libs/blob/main/LICENSE) [![conda](https://img.shields.io/badge/conda-mojo--prometheus-9DAE51)](https://prefix.dev/channels/@amarbaro/amarbaro/packages/mojo-prometheus)
<!-- /badges -->

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-prometheus`.
Toolchains: Mojo 1.2.0 stable and the 1.3 nightly, in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix.

Prometheus metrics for Mojo: counters, gauges, histograms and summaries with labels, and the `/metrics` text exposition (format 0.0.4) byte-identical with Python's `prometheus_client`.

```mojo
from prometheus import Registry


def main() raises:
    var r = Registry()
    var req = r.counter("http_requests", "HTTP requests", ["method", "code"])
    var lat = r.histogram("request_seconds", "Request latency")
    r.inc(r.child(req, "GET", "200"))          # child() = .labels(...), cache the id on hot paths
    r.observe(lat, r.child(lat), 0.042)
    print(r.exposition())                      # serve this as text/plain; version=0.0.4
```

| Call | Does |
|---|---|
| `Registry()` | Holds every metric, in registration order. |
| `r.counter(name, help, labels=[])`, `r.gauge(...)`, `r.summary(...)` | Metric id. A counter's `_total` suffix is added on output. |
| `r.histogram(name, help, labels=[], buckets=DEFAULT_BUCKETS)` | Metric id; `+Inf` is appended. |
| `r.child(metric, *label_values)` | The labelled child, created on first use. |
| `r.inc`, `r.dec`, `r.set`, `r.observe` | Update a child (kind-checked). |
| `r.exposition()` | The text format 0.0.4. |
<!-- /install -->

**Checked against prometheus_client 0.26.0** (created series off): a 436-op script (9 metrics, label values with quotes, backslashes, newlines and Unicode, custom and default buckets, sample-name duplicates, name and label validation, bucket rules, a negative-bucket histogram fed NaN, wrong-kind updates, a negative counter increment) replayed by both, 6 exposition snapshots and 13 error rows byte-identical, plus Go-style float formatting (`1.234567e+06`, `+Inf`, `NaN`), each scenario twice. 9 of 9 mutants caught. Builds and passes on Mojo 1.2.0 and the 1.3 nightly.

**Limits:** names follow prometheus_client's classic validation (`PROMETHEUS_LEGACY_NAME_VALIDATION=true`): metric names `[a-zA-Z_:][a-zA-Z0-9_:]*`, label names `[a-zA-Z_][a-zA-Z0-9_]*`, no `__` labels. The default UTF-8 names of prometheus_client 0.26 (quoted in the output) are not supported. One `Registry` per process; it is not thread-safe.

**Speed** (1,000 labelled children, 7800X3D, pinned core, load average 6.5): `inc` 7 ns (kind-checked), `observe` 25 ns, exposition 3.8 ms; prometheus_client 255 ns, 625 ns and 79 ms.

Floats print exactly as Python's `repr`: Mojo 1.2's own float printing is not round-trip safe, so the sibling library `../pyformat` (mojo-pyformat 0.2) supplies `py_repr`.

- API: [docs/api.md](docs/api.md) · design: [docs/design.md](docs/design.md) · agent skill: [skills/mojo-prometheus/SKILL.md](skills/mojo-prometheus/SKILL.md)
- License: Apache-2.0
