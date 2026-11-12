#!/usr/bin/env bash
# Port the minimum crypto from Mosaad-M-tls (MIT) into src/tls/tls13/_tmp_crypto/ (temporary, wave 2 replaces it).
set -euo pipefail
cd "$(dirname "$0")/.."
S=/home/mario/Projects/imports/tls-refs/Mosaad-M-tls
D=src/tls/tls13/_tmp_crypto
mkdir -p "$D"
for f in hash hmac hkdf aes aes_hw gcm chacha20 poly1305 curve25519 p256 ec_ct bigint random; do
  {
    printf '# TEMPORARY (lane 4, wave 1): ported from Mosaad-M-tls crypto/%s.mojo; lanes 1-2 replace it in wave 2.\n' "$f"
    printf '# MIT License, Copyright (c) 2026 mmosaad; notice in LICENSE-Mosaad-M-tls next to this file.\n'
    sed -E 's/^(from|import) crypto\./\1 tls.tls13._tmp_crypto./' "$S/crypto/$f.mojo"
  } > "$D/$f.mojo"
done
cp "$S/LICENSE" "$D/LICENSE-Mosaad-M-tls"
touch src/tls/__init__.mojo src/tls/tls13/__init__.mojo "$D/__init__.mojo"
grep -n "^from\|^import" "$D"/*.mojo | grep -v "std\." || true
wc -l "$D"/*.mojo | tail -1
