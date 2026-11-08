# Rules

`what broke -> the rule`

- `String(span_of_bytes)` printed `[65, 98]` -> build a String from bytes with `String(unsafe_from_utf8=span)`, never `String(span)`.
- `var f: T = default` in a `@fieldwise_init` struct did not parse (Mojo 1.2) -> to add a defaulted field, write the `__init__` by hand and keep the old positional order.
- A test of `Layer` needs a GPU, and `ui_cpu_test` runs without one -> put pure checks (`image_fits`) in a function the CPU test calls, the GPU path goes in `ui_test`.
