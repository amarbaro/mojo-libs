#!/usr/bin/env bash
# build.sh: build real_server and real_client (TLS_SERVER_BIN / TLS_CLIENT_BIN for tests/interop/run.sh) over lane 4's
# temporary crypto. Package root .work/real is a tree of symlinks so `tls.tls12`, `tls.net` (this repo) and
# `tls.tls13._tmp_crypto` (lane 4, MIT port of Mosaad-M-tls, LANE4 dir below) resolve under one `tls` package; nothing copied.
# Wave 2 deletes this directory when RealCrypto over lanes 1-3 exists. Prints the two binary paths on success.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
LANE4="${LANE4:-/home/mario/Projects/mojo/mojo-tls/.claude/worktrees/wf_7edaec13-638-10/src/tls/tls13/_tmp_crypto}"
MOJO="${MOJO:-/home/mario/Projects/mojo/mojo-tls/.venv/bin/mojo}"
AIO="${AIO:-/home/mario/Projects/mojo/mojo-aio/src}"
[[ -d "$LANE4" ]] || { echo "FAIL build: lane 4 _tmp_crypto not found at $LANE4 (set LANE4)"; exit 1; }
r=.work/real; mkdir -p "$r/tls/tls13" .work/real-bin
: > "$r/tls/__init__.mojo"; : > "$r/tls/tls13/__init__.mojo"
ln -sfn "$root/src/tls/tls12" "$r/tls/tls12"; ln -sfn "$root/src/tls/net" "$r/tls/net"; ln -sfn "$LANE4" "$r/tls/tls13/_tmp_crypto"
for b in real_server real_client; do
  rm -f ".work/real-bin/$b"
  timeout 300 "$MOJO" build -I "$r" -I "$AIO" -I tests/real "tests/real/$b.mojo" -o ".work/real-bin/$b" >".work/real-bin/$b.build" 2>&1 \
    || { echo "FAIL build $b: $(grep -m3 error ".work/real-bin/$b.build")"; exit 1; }
  echo "$root/.work/real-bin/$b"
done
