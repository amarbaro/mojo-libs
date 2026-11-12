#!/usr/bin/env bash
# check.sh [mutants]  Lane 5 gate: build and run every test over the fake crypto, then (with "mutants") prove each
# test file can fail: a mutant of the source that breaks one rule must turn a named test red.
# Prints PASS <step> / FAIL <step>: <reason>; exit 1 on any failure.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
MOJO="${MOJO:-/home/mario/Projects/mojo/mojo-tls/.venv/bin/mojo}"
AIO="${AIO:-/home/mario/Projects/mojo/mojo-aio/src}"
W="$root/.work/check"; mkdir -p "$W"
fail=0
bad() { echo "FAIL $1: $2"; fail=1; }

build() { # name srcdir -> $W/name (rm first: a stale binary must never run)
  local name="$1" src="$2" out="$W/$1"
  rm -f "$out"
  timeout 300 "$MOJO" build -I "$src" -I "$AIO" -I tests "tests/$name.mojo" -o "$out" >"$W/$name.build" 2>&1 || { bad "build $name" "$(grep -m3 error "$W/$name.build")"; return 1; }
}
runt() { # name binary -> runs, echoes the RESULT line
  local out; out="$(timeout 120 "$2" 2>&1)" || { echo "$out" | grep -m5 -E "^FAIL|error" || true; return 1; }
  echo "$out" | grep -E "^RESULT"
}

tests=(t_flow)
for t in "${tests[@]}"; do
  if build "$t" src && r="$(runt "$t" "$W/$t")"; then echo "PASS $t: $r"; else bad "$t" "see output above"; fi
done

if [[ "${1:-}" == mutants ]]; then
  # name | file | sed expression | test that must go red
  mutants=(
    "finished-unchecked|src/tls/tls12/server.mojo|s/if not ct_eq(body, self.cn.finished(\"client finished\")):/if False:/"
    "ems-optional|src/tls/tls12/server.mojo|s/if not ch.ems:/if False:/"
    "no-sentinel|src/tls/tls12/server.mojo|s/if ch.offers13():/if False:/"
    "record-cap-gone|src/tls/tls12/conn.mojo|s/if n > MAX_REC + (2048 if self.rd.on else 0):/if False:/"
    "read-seq-frozen|src/tls/tls12/conn.mojo|s/self.rd.seq += 1/pass/"
    "alpn-any|src/tls/tls12/server.mojo|s/if self.alpn.byte_length() == 0:/if False:/"
    "msg-cap-gone|src/tls/tls12/conn.mojo|s/if l > MAX_MSG:/if False:/"
    "ri-ignored|src/tls/tls12/server.mojo|s/if ch.ri_bad:/if False:/"
    "ccs-anywhere|src/tls/tls12/server.mojo|s/if self.st != 2:/if False:/"
    "aad-seq-zero|src/tls/tls12/conn.mojo|s/self.aad\[i\] = b$/self.aad[i] = 0/"
  )
  pids=()
  for m in "${mutants[@]}"; do
    IFS='|' read -r name file expr <<<"$m"
    (
      d="$W/mut-$name"; rm -rf "$d"; mkdir -p "$d"; cp -r src "$d/src"
      sed -i "$expr" "$d/$file"
      if cmp -s "$file" "$d/$file"; then echo "FAIL mutant $name: sed changed nothing"; exit 0; fi
      rm -f "$d/t_flow"
      if ! timeout 300 "$MOJO" build -I "$d/src" -I "$AIO" -I tests tests/t_flow.mojo -o "$d/t_flow" >"$d/build.log" 2>&1; then
        echo "FAIL mutant $name: does not build: $(grep -m1 error "$d/build.log")"; exit 0; fi
      if out="$(timeout 60 "$d/t_flow" 2>&1)"; then echo "FAIL mutant $name: tests still pass"
      else echo "PASS mutant $name killed by: $(echo "$out" | grep -m1 '^FAIL' || echo "crash: $(echo "$out" | tail -1)")"; fi
    ) >"$W/mut-$name.out" 2>&1 &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  for m in "${mutants[@]}"; do IFS='|' read -r name _ <<<"$m"; cat "$W/mut-$name.out"; grep -q "^FAIL" "$W/mut-$name.out" && fail=1; done
fi
[[ "$fail" -eq 0 ]] && echo "PASS gate" || { echo "FAIL gate: see above"; exit 1; }
