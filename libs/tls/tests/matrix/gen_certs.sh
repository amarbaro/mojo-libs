#!/usr/bin/env bash
# gen_certs.sh OUTDIR: one test CA, default leaves {p256,rsa} (SAN localhost, 127.0.0.1) and SNI leaves {alt-p256,alt-rsa}
# (SAN alt.test). Files: ca.pem, NAME.crt.pem, NAME.key.pem (PKCS#8). Throwaway keys, never leave OUTDIR (under .work/).
set -euo pipefail
out="${1:?usage: gen_certs.sh OUTDIR}"
mkdir -p "$out"; cd "$out"
[[ -f ca.pem && -f p256.crt.pem && -f rsa.crt.pem && -f alt-p256.crt.pem && -f alt-rsa.crt.pem ]] && exit 0
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -subj "/CN=mojo-tls matrix CA" \
  -days 30 -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
leaf() { # name san genpkey-args...
  local n="$1" san="$2"; shift 2
  printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' "$san" > "$n.ext"
  openssl genpkey "$@" -out "$n.key.pem" 2>/dev/null
  openssl req -new -key "$n.key.pem" -subj "/CN=$n" -out "$n.csr" 2>/dev/null
  openssl x509 -req -in "$n.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile "$n.ext" -out "$n.crt.pem" 2>/dev/null
}
leaf p256 "DNS:localhost,IP:127.0.0.1" -algorithm EC -pkeyopt ec_paramgen_curve:P-256
leaf rsa "DNS:localhost,IP:127.0.0.1" -algorithm RSA -pkeyopt rsa_keygen_bits:2048
leaf alt-p256 "DNS:alt.test" -algorithm EC -pkeyopt ec_paramgen_curve:P-256
leaf alt-rsa "DNS:alt.test" -algorithm RSA -pkeyopt rsa_keygen_bits:2048
echo "PASS gen_certs: $out"
