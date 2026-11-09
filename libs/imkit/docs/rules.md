# Rules

`what broke -> the rule`

- `String(span_of_bytes)` printed `[65, 98]` -> build a String from bytes with `String(unsafe_from_utf8=span)`, never `String(span)`.
- `var f: T = default` in a `@fieldwise_init` struct did not parse (Mojo 1.2) -> to add a defaulted field, write the `__init__` by hand and keep the old positional order.
- A test of `Layer` needs a GPU, and `ui_cpu_test` runs without one -> put pure checks (`image_fits`) in a function the CPU test calls, the GPU path goes in `ui_test`.
- `scripts/mutants.sh` sed pattern stopped matching after a fix reworded the line it breaks ("sed changed nothing") -> a mutant's sed must be checked against the current source whenever that line changes; run `scripts/mutants.sh` in the same gate as the change.
- A failed `mojo build` leaves the old binary, and the test then "passed" -> `rm` the binary before building, or read the build's exit status; never trust a PASS from a binary newer than its source.
- Lane A's new `Ui` forwarders ignored `Ui.scale` -> every `Ui` method that takes a position, size, radius, border, glow or offset multiplies by `self.scale`; a new one gets a DPI 1.5 check in `ui_cpu_test`.
- A pixel-equality check between two spots of a translucent glass panel failed because the backdrop gradient differs -> compare neighbours with a tolerance, or against a colour that cannot be the backdrop, and prove the check fails with the feature removed.
- Neon's cyan accent under light text was 1.2 : 1 -> a fill colour needs its own text role (`on_accent`), and every preset's pairs are contrast-tested (WCAG 4.5 text, 3 graphics).

