#!/usr/bin/env bash
# Throughput table for the 5 issue inputs: our zstd (tests/bench31.mojo, level 3) against libzstd via
# `zstd -b3 --single-thread -i1`. Writes .work/i31/bench31.tsv; ratio columns are ours / libzstd speed.
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-.venv/bin/mojo}
W=.work/i31
C=$W/corpus
mkdir -p "$C"
MIB=1048576

# corpus: each file made once, kept for reruns
[[ -s $C/rand ]] || { head -c $((64 * MIB)) /dev/urandom > "$C/rand" || { echo "FAIL setup: rand"; exit 1; }; }
if [[ ! -s $C/rep ]]; then
  # yes ends with SIGPIPE when head stops it: that exit status is expected here
  set +o pipefail
  yes "The quick brown fox jumps over the lazy dog, again and again." | head -c $((64 * MIB)) > "$C/rep"
  set -o pipefail
  [[ $(stat -c %s "$C/rep") -eq $((64 * MIB)) ]] || { echo "FAIL setup: rep"; exit 1; }
fi
if [[ ! -s $C/exe ]]; then
  [[ -r /usr/bin/rclone ]] || { echo "FAIL setup: /usr/bin/rclone missing"; exit 1; }
  head -c 10000000 /usr/bin/rclone > "$C/exe" || { echo "FAIL setup: exe"; exit 1; }
fi
if [[ ! -s $C/src ]]; then
  # the .c files alone total 2.33 MB, so the headers follow them to reach the 2.9 MB cut
  cat .work/i31/ref/zstd-1.5.7/lib/*/*.c .work/i31/ref/zstd-1.5.7/lib/*/*.h > "$W/src.all" || { echo "FAIL setup: src (cat)"; exit 1; }
  [[ $(stat -c %s "$W/src.all") -ge 2900000 ]] || { echo "FAIL setup: src shorter than 2.9 MB"; exit 1; }
  head -c 2900000 "$W/src.all" > "$C/src" || { echo "FAIL setup: src"; exit 1; }
  rm -f "$W/src.all"
fi
if [[ ! -s $C/json ]]; then
  awk 'BEGIN {
    srand(42); total = 0; split("alpha beta gamma delta eps zeta eta theta", ks, " ")
    while (total < 12000000) {
      line = sprintf("{\"id\":%d,\"%s\":\"user_%d\",\"score\":%.4f,\"active\":%s,\"tags\":[\"t%d\",\"g%d\"],\"ts\":%d,\"%s\":%d}",
        n++, ks[int(rand() * 8) + 1], int(rand() * 100000), rand() * 1000,
        (rand() < 0.5 ? "true" : "false"), int(rand() * 50), int(rand() * 7),
        1700000000 + int(rand() * 40000000), ks[int(rand() * 8) + 1], int(rand() * 1000000))
      print line
      total += length(line) + 1
    }
  }' > "$C/json" || { echo "FAIL setup: json"; exit 1; }
  [[ -s $C/json ]] || { echo "FAIL setup: json empty"; exit 1; }
fi

# build
rm -f "$W/bench31"
$MOJO build -I src tests/bench31.mojo -o "$W/bench31" > "$W/bench31.build.log" 2>&1 \
  || { echo "FAIL build: tests/bench31.mojo (see $W/bench31.build.log)"; tail -n 20 "$W/bench31.build.log"; exit 1; }
[[ -x $W/bench31 ]] || { echo "FAIL build: no binary"; exit 1; }

# libzstd parse: last \r-separated segment, then the two MB/s numbers (compress, decompress)
zstd_row() {
  local seg nums
  seg=$(timeout 300 zstd -b3 --single-thread -i1 "$1" 2>&1 | tr '\r' '\n' | grep -E 'MB/s.*MB/s' | tail -n 1) || true
  nums=$(grep -oE '[0-9]+(\.[0-9]+)? MB/s' <<< "$seg" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
  [[ $(wc -l <<< "$nums") -ge 2 ]] || { echo "FAIL run: zstd -b3 parse on $1" >&2; return 1; }
  echo "$(head -n 1 <<< "$nums") $(sed -n 2p <<< "$nums")"
}

ours_row() {
  local line c d s
  line=$(timeout 300 "$W/bench31" "$1") || { echo "FAIL run: bench31 on $1" >&2; return 1; }
  c=$(sed -nE 's/.*c_mbps=([0-9.]+).*/\1/p' <<< "$line")
  d=$(sed -nE 's/.*d_mbps=([0-9.]+).*/\1/p' <<< "$line")
  [[ -n $c && -n $d ]] || { echo "FAIL run: unparsed bench31 line: $line" >&2; return 1; }
  s=$(sed -nE 's/.*csize=([0-9]+).*/\1/p' <<< "$line")
  [[ -n $s ]] || { echo "FAIL run: no csize in bench31 line: $line" >&2; return 1; }
  echo "$c $d $s"
}

OUT=$W/bench31.tsv
{
  printf 'input\tours_c_mbps\tours_d_mbps\tlibzstd_c_mbps\tlibzstd_d_mbps\tc_ratio\td_ratio\tours_bytes\n'
  for name in rand rep exe src json; do
    f=$C/$name
    read -r oc od os < <(ours_row "$f") || { echo "FAIL run: ours $name" >&2; exit 1; }
    read -r lc ld < <(zstd_row "$f") || { echo "FAIL run: libzstd $name" >&2; exit 1; }
    awk -v n="$name" -v oc="$oc" -v od="$od" -v lc="$lc" -v ld="$ld" -v os="$os" \
      'BEGIN { printf "%s\t%s\t%s\t%s\t%s\t%.3f\t%.3f\t%s\n", n, oc, od, lc, ld, oc / lc, od / ld, os }'
  done
} | tee "$OUT" || { echo "FAIL run: table"; exit 1; }
echo "wrote $OUT"
