#!/usr/bin/env bash
# Lane 3 gate: builds tests/x509_gate.mojo once, runs every stage, compares against openssl oracles.
# Usage: tests/gate.sh [stage ...]   stages: parse chain keys bench   (default: parse chain keys)
# Prints PASS/FAIL <stage>: <reason>; exits non-zero on any failure. Artifacts in .work/gate/.
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-/home/mario/Projects/mojo/mojo-tls/.venv/bin/mojo}
W=${W:-.work/gate}
BIN=${BIN:-$W/gate}
BUNDLE=${BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
mkdir -p $W
fail() { echo "FAIL $1: $2"; exit 1; }

build() {
  [ -n "${NOBUILD:-}" ] && return 0
  rm -f $BIN
  timeout 300 $MOJO build -I ${SRC:-src} tests/x509_gate.mojo -o $BIN 2>&1 | grep -E "error" -A4 && fail build "mojo build failed" || true
  [ -x $BIN ] || fail build "no binary"
}

stage_parse() {
  timeout 60 $BIN unit || fail parse "unit vectors"
  timeout 120 $BIN fuzz $BUNDLE 200 || fail parse "fuzz"
  local dir=$W/bundle n=0
  rm -rf $dir && mkdir -p $dir
  awk -v d=$dir '/BEGIN CERTIFICATE/{n++; f=sprintf("%s/%03d.pem", d, n)} f != "" {print > f}' $BUNDLE
  : > $W/bundle_oracle.txt
  for f in $dir/*.pem; do
    local nb na ser key
    nb=$(date -u -d "$(openssl x509 -in $f -noout -startdate | cut -d= -f2)" +%s)
    na=$(date -u -d "$(openssl x509 -in $f -noout -enddate | cut -d= -f2)" +%s)
    ser=$(openssl x509 -in $f -noout -serial | cut -d= -f2 | tr A-Z a-z)
    if openssl x509 -in $f -noout -modulus 2>/dev/null | grep -qE '^Modulus=[0-9A-F]+$'; then
      key=$(openssl x509 -in $f -noout -modulus | cut -d= -f2 | tr A-Z a-z)
    else
      local txt
      txt=$(openssl x509 -in $f -noout -pubkey | openssl pkey -pubin -noout -text 2>/dev/null)
      if echo "$txt" | grep -qE 'ASN1 OID: (prime256v1|secp384r1)'; then
        key=$(echo "$txt" | sed -n '/^pub:/,/^ASN1 OID/p' | grep -v -e '^pub:' -e '^ASN1' | tr -d ' :\n')
      else
        key=-
      fi
    fi
    echo "$nb $na $ser $key" >> $W/bundle_oracle.txt
    n=$((n + 1))
  done
  $BIN bundle $BUNDLE > $W/bundle_ours.txt || fail parse "bundle parse"
  local want have
  want=$(grep -c 'BEGIN CERTIFICATE' $BUNDLE)
  have=$(wc -l < $W/bundle_ours.txt)
  [ "$want" = "$have" ] || fail parse "parsed $have of $want bundle certs"
  diff <(cat $W/bundle_oracle.txt) <(cat $W/bundle_ours.txt) > $W/bundle.diff || { head -5 $W/bundle.diff; fail parse "fields differ from openssl on $(grep -c '^<' $W/bundle.diff) certs"; }
  echo "PASS parse: all $have certs of $BUNDLE parse; not_before, not_after, serial and key bytes equal openssl's"
}

build
stages=("$@")
[ ${#stages[@]} -eq 0 ] && stages=(parse chain keys)
for s in "${stages[@]}"; do "stage_$s"; done
