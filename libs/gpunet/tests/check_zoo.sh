#!/usr/bin/env bash
# check_zoo.sh MODEL (gate G2.1): one zoo model on GpuNet against its independent oracle, thresholds of plan 5.2, licence row required.
#   siglip-v1-text  R6a: SigLIP v1 text tower, 200 prompts, PyTorch oracle (tests/zoo/siglip-v1-text.*), arms fp32 batch 1 and 16, fp16 batch 16;
#                   planted token fault and normalisation fault (mutant built from a mutated copy of src/), shuffled-caption control
#   det_10g         R5a: SCRFD-10G graph and decode head against onnxruntime on JPEGs of $DET_LIST (first $DET_N), arms fp32 and fp16;
#                   planted anchor shift (mutant of decode.mojo); images with zero detections are the clean control
# Roots: only this tree's src/ and its sibling libs/mmap/src go on the include path (printed below, checked to be one git tree). The mutant
# arms prove the include path decides what runs: a mutated copy of src/ must fail the same comparison the clean build passes.
# Exit 0 PASS, 1 FAIL, 3 BLOCK (a part that could not run or was never built; a skip is never a pass). GPU runs go through gpu-wait --shared.
set -uo pipefail
M=${1:?usage: check_zoo.sh siglip-v1-text|det_10g}
cd "$(dirname "$0")/.."; G=$PWD; Z=$G/tests/zoo; W=$G/.work/zoo/$M; rm -rf "$W"; mkdir -p "$W"
FSW=${FS_WORK:-$HOME/Projects/mojo/mojo-libs/.work/fs}
fails=0; blocks=0; why=""
fail() { echo "FAIL check_zoo $M: $1"; fails=$((fails + 1)); }
block() { echo "BLOCK check_zoo $M: $1"; blocks=$((blocks + 1)); why="$why; $1"; }
ok() { echo "ok $1"; }
MOJO=${MOJO:-}
[ -n "$MOJO" ] || for c in "$G/../cv/.venv/bin/mojo" "$HOME/Projects/mojo/mojo-libs/libs/cv/.venv/bin/mojo"; do [ -x "$c" ] && { MOJO=$c; break; }; done
[ -n "$MOJO" ] || { echo "BLOCK check_zoo $M: no mojo compiler (set MOJO)"; exit 3; }
top=$(git -C "$G" rev-parse --show-toplevel); [ "$(git -C "$G/../mmap" rev-parse --show-toplevel)" = "$top" ] || { echo "FAIL check_zoo $M: libs/mmap is outside this git tree"; exit 1; }
echo "roots: gpunet=$G tree=$top head=$(git -C "$G" rev-parse --short HEAD) dirty=$(git -C "$G" status --porcelain -- . | wc -l) compiler=$MOJO"
echo "include: -I $G/src -I $(realpath "$G/../mmap/src") (nothing else for the model builds)"

build() {  # SRCDIR MAIN OUT [EXTRA -I ...]: gfx1100 build with only SRCDIR and mmap on the path
  local src=$1 main=$2 out=$3; shift 3
  "$MOJO" build -I "$src" -I "$G/../mmap/src" "$@" --target-accelerator gfx1100 "$main" -o "$out" 2> "$out.err" || { grep -m5 -A4 "error:" "$out.err"; fail "build $main from $src"; return 1; }
}
gpu() { gpu-wait run --shared --vram 2 --timeout 300 --mem 8 --label "fs-zoo-$M" -- "$@"; }
lic() {  # FILE: the licence row of the checkpoint (by sha256), required
  local f=$1 s row
  [ -f "$f" ] || { block "checkpoint $f missing"; return 1; }
  s=$(sha256sum "$f" | cut -d' ' -f1); row=$(grep -F "$s" "$FSW/licences/models.tsv" 2> /dev/null | head -1)
  [ -n "$row" ] || { block "no licence row for $f (sha256 $s) in $FSW/licences/models.tsv"; return 1; }
  local st; st=$(cut -f7 <<< "$row"); echo "licence row: $(cut -f1 <<< "$row") sha256 ${s:0:12} licence_status=$st"
  case $st in CLEARED*) ;; *) echo "NOTE licence $st: no redistribution or 'accepted' claim from this gate";; esac
}
inc_sha() { cat "$1"/gpunet/*.mojo "$1"/gpunet/gpu/*.mojo | sha256sum | cut -c1-12; }

case $M in
siglip-v1-text)
  MODEL=${MODEL:-$HOME/Models/siglip-base-patch16-224-onnx/onnx/model.onnx}; TOK=${SIGLIP_TOK:-$HOME/Models/siglip-base-patch16-224-tok}
  lic "$MODEL"; lic "$TOK/tokenizer.json" || true
  for f in prompts ids hidden.f32 proj.f32 emb.f32; do echo "fixture $(sha256sum "$Z/siglip-v1-text.$f" | cut -c1-16) siglip-v1-text.$f"; done
  [ "$(wc -l < "$Z/siglip-v1-text.prompts")" = 200 ] || fail "prompts file is not 200 lines"
  build "$G/src" tests/zoo_text.mojo "$W/zoo_text" || exit 1
  echo "clean src hash $(inc_sha "$G/src")"
  run() {  # TAG ARM BATCH IDS [BIN]: GPU rows into $W/TAG
    mkdir -p "$W/$1"; gpu "${5:-$W/zoo_text}" "$MODEL" "$4" "$W/$1" "$2" "$3" > "$W/$1.log" 2>&1 || { tail -3 "$W/$1.log"; fail "gpu run $1"; return 1; }
  }
  run f32b1 32 1 "$Z/siglip-v1-text.ids" && { echo "arm fp32 batch 1:"; python3 -I "$Z/cmp_text.py" "$W/f32b1" > "$W/f32b1.cmp" || fail "parity fp32 batch 1"; cat "$W/f32b1.cmp"; }
  run f32b16 32 16 "$Z/siglip-v1-text.ids" && { echo "arm fp32 batch 16:"; python3 -I "$Z/cmp_text.py" "$W/f32b16" > "$W/f32b16.cmp" || fail "parity fp32 batch 16"; cat "$W/f32b16.cmp"; }
  run f16b16 16 16 "$Z/siglip-v1-text.ids" && { echo "arm fp16 batch 16 (plan: cosine 0.999; paired scores 1e-3; the 1e-3 relative abs bound is fp32 only):"
    python3 -I "$Z/cmp_text.py" "$W/f16b16" 0.999 1e9 1e-3 > "$W/f16b16.cmp" || fail "parity fp16 batch 16"; cat "$W/f16b16.cmp"; }
  # planted token fault: the first token of every prompt moved by one id; the comparison must fail
  python3 -I - "$Z/siglip-v1-text.ids" "$W/ids.fault" << 'EOF2'
import sys
rows = [l.split() for l in open(sys.argv[1])]
open(sys.argv[2], "w").write("\n".join(" ".join([str(int(r[0]) + 1)] + r[1:]) for r in rows) + "\n")
EOF2
  if run fault 32 16 "$W/ids.fault"; then
    if python3 -I "$Z/cmp_text.py" "$W/fault" > "$W/fault.cmp" 2>&1; then fail "planted token fault passed the comparison"; else ok "planted token fault failed the comparison: $(grep -m1 '^hidden' "$W/fault.cmp")"; fi
  fi
  # planted normalisation fault: a mutant build that skips the L2 normalisation
  mkdir -p "$W/mutnorm"; cp -r "$G/src" "$W/mutnorm/src"
  sed -i 's/emb.append(row\[k\] \* inv)/emb.append(row[k])/' "$W/mutnorm/src/gpunet/text.mojo"
  if cmp -s "$G/src/gpunet/text.mojo" "$W/mutnorm/src/gpunet/text.mojo"; then fail "normalisation mutant: patch did not apply"
  elif build "$W/mutnorm/src" tests/zoo_text.mojo "$W/mutnorm/zoo_text"; then
    echo "mutant normalisation: dependency text.mojo clean $(sha256sum < "$G/src/gpunet/text.mojo" | cut -c1-12) mutant $(sha256sum < "$W/mutnorm/src/gpunet/text.mojo" | cut -c1-12)"
    if run mutnorm 32 16 "$Z/siglip-v1-text.ids" "$W/mutnorm/zoo_text"; then
      if python3 -I "$Z/cmp_text.py" "$W/mutnorm" > "$W/mutnorm.cmp" 2>&1; then fail "normalisation mutant survived"; else ok "normalisation mutant killed: $(grep -m1 '^normalisation' "$W/mutnorm.cmp")"; fi
    fi
  fi
  # tokenizer: the ids of libs/tokenizers + siglabel.mojo against the HF ids; ASCII prompts gate, the rest is counted
  "$MOJO" build -O3 -I "$G/src" -I "$G/../cv/src" -I "$G/../mmap/src" -I "$G/../tokenizers/src" -I "$G/../uregex/src" -I "$G/../json/src" -I "$G/../gzip/src" "$G/../cv/src/siglabel.mojo" -o "$W/mcv-labels" 2> "$W/mcv-labels.err" || { grep -m3 -A3 "error:" "$W/mcv-labels.err"; fail "build siglabel.mojo"; }
  if [ -x "$W/mcv-labels" ]; then
    jq -c '.normalizer.normalizers = [.normalizer.normalizers[4], .normalizer.normalizers[5]] | .model.byte_fallback = false' "$TOK/tokenizer.json" > "$W/tokenizer_pre.json"
    "$W/mcv-labels" tok "$W/tokenizer_pre.json" "$Z/siglip-v1-text.prompts" "$W/mojo.ids"
    python3 -I - "$Z/siglip-v1-text.prompts" "$Z/siglip-v1-text.ids" "$W/mojo.ids" << 'EOF2'
import sys
p = open(sys.argv[1], encoding="utf-8").read().split("\n")[:-1]; a = [l.split() for l in open(sys.argv[2])]; b = [l.split() for l in open(sys.argv[3])]
asc = [i for i, t in enumerate(p) if t.isascii()]; non = [i for i, t in enumerate(p) if not t.isascii()]
ba = [i for i in asc if a[i] != b[i]]; bn = [i for i in non if a[i] != b[i]]
print(f"tokenizer ids vs HF SiglipTokenizer: ASCII prompts {len(asc) - len(ba)} of {len(asc)} equal; non-ASCII prompts {len(non) - len(bn)} of {len(non)} equal")
if ba: print("FAIL tokenizer: ASCII prompt rows differ:", ba[:10]); sys.exit(1)
if bn: print(f"BLOCK tokenizer native languages: {len(bn)} of {len(non)} non-ASCII prompts get other ids (libs/tokenizers has no byte fallback and is not an S1 path; canon in siglabel.mojo lowercases ASCII only)"); sys.exit(3)
EOF2
    case $? in 0) ;; 3) block "native-language token ids differ from HF on non-ASCII prompts (see tokenizer line)";; *) fail "tokenizer ids differ on ASCII prompts";; esac
  fi
  block "v2 export: none on disk (SigLIP2 row ABSENT in models.tsv); R6b needs an export, its tokenizer and its own oracle"
  ;;
det_10g)
  MODEL=${MODEL:-$HOME/Models/deep-live-cam-models/buffalo_l/buffalo_l/det_10g.onnx}; LIST=${DET_LIST:-$FSW/inputs/index-list.txt}; N=${DET_N:-12}
  lic "$MODEL"
  [ -f "$LIST" ] || { echo "BLOCK check_zoo $M: list $LIST missing"; exit 3; }
  echo "list $LIST sha256 $(sha256sum "$LIST" | cut -c1-16) first $N images"
  mkdir -p "$W/ref"; python3 -I "$Z/oracle_det.py" "$MODEL" "$LIST" "$W/ref" "$N" || { fail "oracle_det.py"; exit 1; }
  build "$G/src" tests/zoo_det.mojo "$W/zoo_det" || exit 1
  echo "clean src hash $(inc_sha "$G/src")"
  for a in 32 16; do
    mkdir -p "$W/a$a"; gpu "$W/zoo_det" "$MODEL" "$W/ref/blobs.list" "$W/a$a" $a > "$W/a$a.log" 2>&1 || { tail -3 "$W/a$a.log"; fail "gpu run arm $a"; continue; }
    python3 -I "$Z/cmp_det.py" "$W/a$a" "$W/ref" "$N" $a > "$W/a$a.cmp" || fail "parity arm $a"; cat "$W/a$a.cmp"
  done
  zero=$(for f in "$W"/ref/*.det.tsv; do [ -s "$f" ] || echo "$f"; done | wc -l)
  [ "$zero" -ge 1 ] && ok "control: $zero of $N images have no detection in the oracle and none on GpuNet (arm 32 counts equal per image)" || block "no image without a detection in the first $N: no clean control in this list"
  # planted anchor shift: a mutant decode.mojo that moves every anchor centre down by one cell; the box comparison must fail
  mkdir -p "$W/mutdec"; cp -r "$G/src" "$W/mutdec/src"
  sed -i 's|var cy = Float32((cell // gw) \* st)|var cy = Float32((cell // gw + 1) * st)|' "$W/mutdec/src/gpunet/decode.mojo"
  if cmp -s "$G/src/gpunet/decode.mojo" "$W/mutdec/src/gpunet/decode.mojo"; then fail "anchor mutant: patch did not apply"
  elif build "$W/mutdec/src" tests/zoo_det.mojo "$W/mutdec/zoo_det"; then
    echo "mutant anchor: dependency decode.mojo clean $(sha256sum < "$G/src/gpunet/decode.mojo" | cut -c1-12) mutant $(sha256sum < "$W/mutdec/src/gpunet/decode.mojo" | cut -c1-12)"
    mkdir -p "$W/amut"
    if gpu "$W/mutdec/zoo_det" "$MODEL" "$W/ref/blobs.list" "$W/amut" 32 > "$W/amut.log" 2>&1; then
      if python3 -I "$Z/cmp_det.py" "$W/amut" "$W/ref" "$N" 32 > "$W/amut.cmp" 2>&1; then fail "anchor mutant survived"; else ok "anchor mutant killed: $(grep -m1 '^FAIL' "$W/amut.cmp")"; fi
    else tail -3 "$W/amut.log"; fail "gpu run anchor mutant"; fi
  fi
  [ -f "${CLEAN_LIST:-$FSW/inputs/clean-46.list}" ] || block "false-positive ceiling needs the frozen clean set of 46 accepted images: no list on disk (set CLEAN_LIST)"
  block "planted pasted hand, border boxes, tiled recall and suppression: need the R5b tiler and a hand fixture (R12d); not built"
  ;;
*) echo "FAIL usage: unknown model $M (siglip-v1-text, det_10g)"; exit 2 ;;
esac

if [ $fails -gt 0 ]; then echo "FAIL check_zoo $M: $fails failed part(s), $blocks blocked"; exit 1; fi
if [ $blocks -gt 0 ]; then echo "BLOCK check_zoo $M: numeric parts passed; blocked: ${why#; }"; exit 3; fi
echo "PASS check_zoo $M"
