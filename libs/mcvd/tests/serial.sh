#!/usr/bin/env bash
# serial.sh (gate R2a, serialized proof of plan 3.2): typed ops replayed through the socket equal the bytes of the direct run, and the daemon
# survives the faults a client can send. Every binary is built from this tree (include path printed and checked to one git tree); the direct
# runs are gpunet's own zoo_text / zoo_det built from the same tree.
#   parity     siglip_text (fp32, batch 16) and run det_10g (fp32, 12 JPEGs of the index list) through mcvd: byte-equal to the direct run
#   interleave two clients at once, each its own half of the prompts (batch 10), each equal to its slice of the direct run
#   faults     unknown op, unknown model, bad magic, an oversized frame (refused from the prefix), a short frame (status timeout after 5 s),
#              a client that hangs up mid frame: each answers its status or closes, and the daemon keeps serving
#   lifecycle  a second instance exits 3 and leaves the first serving; SIGKILL then restart takes the stale lock and socket
#   planted    a daemon built from a mutated copy of src/ (ids shifted by one) must fail the parity comparison
# Not here (R2b, G3.1): forced termination mid request with card memory back to baseline, the queue of 32 and busy, deadlines, residency.
# Exit 0 PASS, 1 FAIL, 3 BLOCK.
set -uo pipefail
cd "$(dirname "$0")/.."; D=$PWD; L=$(realpath "$D/.."); G=$L/gpunet; W=$D/.work/serial; rm -rf "$W"; mkdir -p "$W"
FSW=${FS_WORK:-$HOME/Projects/mojo/mojo-libs/.work/fs}
TEXT=${MODEL_TEXT:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; DET=${MODEL_DET:-$HOME/Models/deep-live-cam-models/buffalo_l/buffalo_l/det_10g.onnx}
LIST=${DET_LIST:-$FSW/inputs/index-list.txt}; N=${DET_N:-12}
fails=0; why=""
fail() { echo "FAIL serial: $1"; fails=$((fails + 1)); }
ok() { echo "ok $1"; }
MOJO=${MOJO:-}
[ -n "$MOJO" ] || for c in "$L/cv/.venv/bin/mojo" "$HOME/Projects/mojo/mojo-libs/libs/cv/.venv/bin/mojo"; do [ -x "$c" ] && { MOJO=$c; break; }; done
[ -n "$MOJO" ] || { echo "BLOCK serial: no mojo compiler (set MOJO)"; exit 3; }
for f in "$TEXT" "$DET" "$LIST"; do [ -f "$f" ] || { echo "BLOCK serial: input $f missing"; exit 3; }; done
top=$(git -C "$D" rev-parse --show-toplevel)
for r in gpunet mmap posix msgpack; do [ "$(git -C "$L/$r" rev-parse --show-toplevel)" = "$top" ] || { echo "FAIL serial: libs/$r is outside this git tree"; exit 1; }; done
echo "roots: mcvd=$D tree=$top head=$(git -C "$D" rev-parse --short HEAD) dirty=$(git -C "$D" status --porcelain -- . | wc -l) compiler=$MOJO"
INC="-I $D/src -I $G/src -I $L/mmap/src -I $L/posix/src -I $L/msgpack/src"; echo "include: $INC"
build() { "$MOJO" build $INC "$@" 2> "$W/build.err" || { grep -m5 -A4 "error:" "$W/build.err"; fail "build $*"; return 1; }; }
build --target-accelerator gfx1100 src/serve.mojo -o "$W/mcvd" || exit 1
build tests/mcvc.mojo -o "$W/mcvc" || exit 1
build --target-accelerator gfx1100 "$G/tests/zoo_text.mojo" -o "$W/zoo_text" || exit 1
build --target-accelerator gfx1100 "$G/tests/zoo_det.mojo" -o "$W/zoo_det" || exit 1
gpu() { gpu-wait run --shared --vram 2 --timeout 300 --mem 8 --label mcvd-serial -- "$@"; }

# direct references
mkdir -p "$W/d16" "$W/d10" "$W/ref" "$W/ddet"
IDS=$G/tests/zoo/siglip-v1-text.ids
gpu "$W/zoo_text" "$TEXT" "$IDS" "$W/d16" 32 16 > "$W/d16.log" 2>&1 || fail "direct text batch 16"
gpu "$W/zoo_text" "$TEXT" "$IDS" "$W/d10" 32 10 > "$W/d10.log" 2>&1 || fail "direct text batch 10"
python3 -I "$G/tests/zoo/oracle_det.py" "$DET" "$LIST" "$W/ref" "$N" > /dev/null || fail "oracle_det.py (blobs)"
gpu "$W/zoo_det" "$DET" "$W/ref/blobs.list" "$W/ddet" 32 > "$W/ddet.log" 2>&1 || fail "direct det"
[ $fails = 0 ] || exit 1

PIDS=""
trap 'for p in $PIDS; do kill -TERM $p 2> /dev/null; done' EXIT
start() {  # DIR BIN TAG: a daemon with both models under gpu-wait; sets PID and S (socket)
  mkdir -p "$1"; : > "$W/$3.log"
  gpu-wait run --shared --vram 4 --timeout 900 --mem 8 --label "mcvd-$3" -- "$2" "$1" siglip=text:32:"$TEXT" det=run:32:"$DET" > "$W/$3.log" 2>&1 &
  for _ in $(seq 1 90); do grep -q "^mcvd: ready" "$W/$3.log" && break; sleep 2; done
  grep -q "^mcvd: ready" "$W/$3.log" || { cat "$W/$3.log" | tail -5; fail "daemon $3 did not become ready"; return 1; }
  PID=$(sed -n 's/^mcvd: pid //p' "$W/$3.log"); PIDS="$PIDS $PID"; S=$1/mcvd.sock
}
stop() { kill -TERM "$1" 2> /dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2> /dev/null || return 0; sleep 1; done; kill -KILL "$1" 2> /dev/null; }
text_parity() {  # SOCK OUT: client text replay of all 200 prompts, batch 16, bytes against the direct batch-16 run
  "$W/mcvc" text "$1" siglip "$IDS" "$2" 16 > /dev/null && cmp -s "$2" "$W/d16/emb.f32"
}

start "$W/rt" "$W/mcvd" main || exit 1
S1=$S; P1=$PID
text_parity "$S1" "$W/via-text.f32" && ok "parity siglip_text: 200 prompts through the socket equal the direct run byte for byte (batch 16)" || fail "parity siglip_text differs from the direct run"
mkdir -p "$W/via-det"; "$W/mcvc" run "$S1" det input.1 "$W/ref/blobs.list" "$W/via-det" > /dev/null; bad=0
for f in "$W"/ddet/*.raw.f32; do cmp -s "$f" "$W/via-det/${f##*/}" || bad=$((bad + 1)); done
[ $bad = 0 ] && [ -f "$W/via-det/00.raw.f32" ] && ok "parity run det_10g: $N images, all nine outputs equal the direct run byte for byte" || fail "parity run det_10g: $bad of $N differ"

# interleaved clients, each its own half
"$W/mcvc" text "$S1" siglip "$IDS" "$W/ia.f32" 10 0 100 > /dev/null & pa=$!
"$W/mcvc" text "$S1" siglip "$IDS" "$W/ib.f32" 10 100 100 > /dev/null & pb=$!
wait $pa; wait $pb
if cmp -s "$W/ia.f32" <(head -c $((100 * 3072)) "$W/d10/emb.f32") && cmp -s "$W/ib.f32" <(tail -c +$((100 * 3072 + 1)) "$W/d10/emb.f32") && ! cmp -s "$W/ia.f32" "$W/ib.f32"; then
  ok "interleaved: two clients at once, each equal to its own slice of the direct run, and the two differ"
else fail "interleaved clients: a client got another's or wrong bytes"; fi

# faults
exp() {  # MODE EXPECTED_ERE
  local o; o=$("$W/mcvc" "$1" "$S1" 2>&1 | tail -1)
  if grep -Eq "$2" <<< "$o"; then ok "fault $1: $o"; else fail "fault $1: got '$o', wanted $2"; fi
  [ "$("$W/mcvc" ping "$S1" 2>&1 | tail -1)" = "status=ok" ] || fail "daemon not serving after fault $1"
}
exp badop '^status=unknown_op$'; exp badmodel '^status=unknown_model$'; exp badmagic '^status=bad_frame$'; exp big '^status=bad_frame$'
exp drop '^dropped$'; exp short '^status=timeout$'
kill -0 "$P1" 2> /dev/null && ok "daemon pid $P1 alive after all faults" || fail "daemon died"

# lifecycle: second instance, then SIGKILL and restart
ino=$(stat -c %i "$S1")
"$W/mcvd" "$W/rt" > "$W/second.log" 2>&1; rc=$?
[ $rc = 3 ] && [ "$(stat -c %i "$S1")" = "$ino" ] && [ "$("$W/mcvc" ping "$S1" | tail -1)" = "status=ok" ] && ok "second instance exited 3, socket untouched, first still serving ($(head -1 "$W/second.log"))" || fail "second instance: exit $rc"
kill -KILL "$P1"; sleep 1
start "$W/rt" "$W/mcvd" restart || exit 1
[ "$("$W/mcvc" ping "$S" | tail -1)" = "status=ok" ] && text_parity "$S" "$W/via-text2.f32" && ok "restart after SIGKILL: stale lock and socket taken over, parity again equal" || fail "restart after SIGKILL"
stop "$PID"

# planted: a daemon whose siglip_text shifts every id by one must fail the parity comparison
mkdir -p "$W/mut"; cp -r "$D/src" "$W/mut/src"; sed -i 's/ids\.append(Int(x))/ids.append(Int(x) + 1)/' "$W/mut/src/mcvd/server.mojo"
if cmp -s "$D/src/mcvd/server.mojo" "$W/mut/src/mcvd/server.mojo"; then fail "mutant: patch did not apply"; else
  "$MOJO" build -I "$W/mut/src" -I "$G/src" -I "$L/mmap/src" -I "$L/posix/src" -I "$L/msgpack/src" --target-accelerator gfx1100 "$W/mut/src/serve.mojo" -o "$W/mut/mcvd" 2> "$W/build.err" || { grep -m3 -A3 "error:" "$W/build.err"; fail "build mutant"; }
  if [ -x "$W/mut/mcvd" ]; then
    echo "mutant daemon: server.mojo clean $(sha256sum < "$D/src/mcvd/server.mojo" | cut -c1-12) mutant $(sha256sum < "$W/mut/src/mcvd/server.mojo" | cut -c1-12)"
    start "$W/rtm" "$W/mut/mcvd" mut && { if text_parity "$S" "$W/via-mut.f32"; then fail "mutant daemon passed the parity comparison"; else ok "mutant daemon killed: its text rows differ from the direct run"; fi; stop "$PID"; }
  fi
fi
[ $fails -gt 0 ] && { echo "FAIL serial: $fails check(s) failed"; exit 1; }
echo "PASS serial"
