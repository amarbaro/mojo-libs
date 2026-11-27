#!/usr/bin/env bash
# Pass one 6144x3456 JPEG from the original benchmark list. Use JPEG_CPU to pin a specific available CPU.
set -euo pipefail
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }
scope() { systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 "$@"; }
[ "$#" = 1 ] && [ -s "$1" ] || fail usage 'jpeg_speed.sh /path/to/21MP.jpg'
jpeg=$(realpath -e -- "$1") || fail setup 'benchmark JPEG missing'
cd "$(dirname "$0")/.."
cpu=${JPEG_CPU:-$(awk '/^Cpus_allowed_list:/ {sub(/[-,].*/, "", $2); print $2}' /proc/self/status)}
mkdir -p .work
work=$(mktemp -d .work/jpeg-speed.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
scope timeout 20 "${MOJO:-mojo}" build -O3 -I src tests/jpeg_baseline.mojo -o "$work/check" || fail build 'Mojo oracle'
for mode in rss-turbo rss-native; do
  scope timeout 20 taskset -c "$cpu" /usr/bin/time -f "$mode wall_seconds=%e peak_rss_kib=%M" "$work/check" "$mode" "$jpeg" ||
    fail memory "$mode"
done
scope timeout 20 taskset -c "$cpu" "$work/check" speed "$jpeg" || fail speed 'one-core decode gate'
