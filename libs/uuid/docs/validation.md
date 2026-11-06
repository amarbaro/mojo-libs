# Validation

- `MOJO=mojo scripts/ci.sh`: full stable suite, differential rows, API, example, mutants.
- `scripts/nightly.sh`: nightly package precompile, every tests/test_*.mojo and example.
- `MOJO=mojo scripts/bench.sh`: paired benchmark with preserved .work/bench-before binary.
- `python3 -I tools/check_reference.py`: verify error expectations against pinned source.

Fetch the pinned reference before that last check:

```sh
gh api 'repos/python/cpython/contents/Lib/uuid.py?ref=v3.14.0' --jq .content | base64 -d > .work/cpython-uuid.py
```

RFC goldens are copied from https://www.rfc-editor.org/rfc/rfc9562.txt.
`tests/golden/APPENDIX.txt` preserves the Appendix A.2 through B.2 text verbatim;
`rfc9562.txt` indexes each final value and constants with its section.
`SOURCE` records provenance. No Python script writes a golden file.

The fixed scaffold mutant runner compiles each changed source before checking its
behaviour. Fields in tests/mutants.txt use `|` separators, so patterns must not
contain that character. Its restore trap protects the source on interruption.

Every compile and executable test uses scripts/run-capped.sh (4 GB, no swap,
120 seconds). Stable dependency includes mojo-hashlib-public/src beside this clone.
