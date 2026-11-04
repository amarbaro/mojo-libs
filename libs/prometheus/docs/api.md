# API

`from prometheus import Registry, DEFAULT_BUCKETS, go_float`

| Call | Does |
|---|---|
| `Registry()` | Holds every metric, in registration order. |
| `r.counter(name, help, labels=[]) -> Int` | Metric id. A trailing `_total` in `name` is dropped; samples are `name_total`. Duplicate names raise. |
| `r.gauge(...)`, `r.summary(...)` | Same shape. A summary exports `_count` and `_sum` (no quantiles, as prometheus_client). |
| `r.histogram(name, help, labels=[], buckets=DEFAULT_BUCKETS)` | `+Inf` appended if missing; unsorted buckets raise. |
| `r.child(metric, *label_values) -> Int` | The labelled child (like `.labels(...)`), created on first use. Wrong count raises. An unlabelled metric's child is `r.child(metric)`. |
| `r.inc(child, v=1.0)` | Counter or gauge; negative raises on a counter. |
| `r.dec(child, v=1.0)`, `r.set(child, v)` | Gauge. |
| `r.observe(metric, child, v)` | Histogram (first bucket with `v <= bound`) or summary. |
| `r.exposition() -> String` | The text format, `# HELP` / `# TYPE` per metric, labels sorted by name. |
| `go_float(x) -> String` | prometheus_client `floatToGoString`. |
