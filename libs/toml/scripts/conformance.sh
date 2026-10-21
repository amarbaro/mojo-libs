#!/usr/bin/env bash
# Build the decoder and run toml-test (TOML 1.1). TOML_TEST = path to the toml-test binary.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TOML_TEST:?FAIL setup: set TOML_TEST to the toml-test v2 binary}"
mkdir -p .work
.venv/bin/mojo build -I src tests/decoder.mojo -o .work/decoder || { echo "FAIL build: decoder"; exit 1; }
"$TOML_TEST" test -toml 1.1 -decoder ./.work/decoder -timeout 5s || { echo "FAIL conformance: toml-test 1.1"; exit 1; }
