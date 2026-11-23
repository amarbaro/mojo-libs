#!/usr/bin/env bash
# gpunet CI (gate G1.1): (1) IMPORT.md names mojo-faces deea3f5, the six files and the notices; (2) each imported file equals
# `git -C mojo-faces show deea3f5:<path>` except its import lines (and, for gpu/net.mojo, the recorded patches/net-embed-gather.diff), which differ only by faces. -> gpunet. (a planted edit and a
# planted import change must fail this check); (3) tests/smoke.mojo builds for gfx1100 with only gpunet and mmap on the path and runs.
# Roots: MOJO_PROJECTS (default ~/Projects/mojo) holds mojo-faces; the include paths are this tree's. MOJO picks the compiler.
set -euo pipefail
cd "$(dirname "$0")/.."; G=$PWD; mkdir -p .work
P=${MOJO_PROJECTS:-$HOME/Projects/mojo}; F=$P/mojo-faces; SHA=deea3f5
FILES="onnx.mojo nn.mojo gpu/net.mojo gpu/kernels.mojo gpu/gemm16.mojo gpu/gemm32.mojo"
block() { echo "BLOCK ci gpunet: $1"; exit 3; }
git -C "$F" cat-file -e "$SHA^{commit}" 2>/dev/null || block "mojo-faces at $F has no commit $SHA"
IMP='^[[:space:]]*(from|import) '

# (1) the record
for w in "$SHA" LICENSE "Copied from mojo-baro kernels/matmul.mojo @ 32408f3" "Copied from mojo-baro kernels/matmul_wmma_lds.mojo @ 32408f3" $FILES; do
  case $w in *.mojo) grep -qF "${w##*/}" IMPORT.md || { echo "FAIL record: IMPORT.md does not name $w"; exit 1; };; *) grep -qF "$w" IMPORT.md || { echo "FAIL record: IMPORT.md lacks '$w'"; exit 1; };; esac
done
[ "$(git -C "$F" show "$SHA:LICENSE" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < LICENSE | cut -d' ' -f1)" ] || { echo "FAIL notice: LICENSE differs from faces $SHA"; exit 1; }
grep -q '^# Copied from mojo-baro kernels/matmul.mojo @ 32408f3' src/gpunet/gpu/gemm32.mojo || { echo "FAIL notice: gemm32.mojo header lost"; exit 1; }
grep -q '^# Copied from mojo-baro kernels/matmul_wmma_lds.mojo @ 32408f3' src/gpunet/gpu/gemm16.mojo || { echo "FAIL notice: gemm16.mojo header lost"; exit 1; }

# (2) equal to the source except import lines
same() {  # same ROOT: every file under ROOT/src/gpunet equals the source (non-import lines byte-equal, import lines mapped)
  local r=$1 f
  for f in $FILES; do
    local want; want=$(git -C "$F" show "$SHA:src/faces/$f") || return 2
    if [ "$f" = gpu/net.mojo ]; then  # the one recorded divergence (IMPORT.md, Divergences): the non-import difference must equal patches/net-embed-gather.diff
      diff <(grep -Ev "$IMP" <<< "$want") <(grep -Ev "$IMP" "$r/src/gpunet/$f") | cmp -s - "$G/patches/net-embed-gather.diff" || { echo "differs (beyond the recorded patch): $f"; return 1; }
    else
      diff <(grep -Ev "$IMP" <<< "$want") <(grep -Ev "$IMP" "$r/src/gpunet/$f") > /dev/null || { echo "differs (not import lines): $f"; return 1; }
    fi
    diff <(grep -E "$IMP" <<< "$want" | sed -E 's/\bfaces\.gpu\./gpunet.gpu./g; s/\bfaces\.(onnx|nn)\b/gpunet.\1/g') <(grep -E "$IMP" "$r/src/gpunet/$f") > /dev/null || { echo "differs (import lines): $f"; return 1; }
  done
}
same "$G" || { echo "FAIL import: a file differs from faces $SHA"; exit 1; }
T=$(mktemp -d "$G/.work/ci.XXXXXX"); trap 'rm -rf "$T"' EXIT
for k in code import; do   # planted failures: one edited code line, one import line changed; each must be caught
  mkdir -p "$T/$k"; cp -r src "$T/$k/"
  if [ $k = code ]; then sed -i '0,/^    var /s//    var /; 0,/ + /s// - /' "$T/$k/src/gpunet/nn.mojo"; else sed -i '0,/^from gpunet\.onnx import/s//from gpunet.onnx2 import/' "$T/$k/src/gpunet/nn.mojo"; fi
  cmp -s src/gpunet/nn.mojo "$T/$k/src/gpunet/nn.mojo" && { echo "FAIL plant: the $k plant changed nothing"; exit 1; }
  same "$T/$k" > /dev/null 2>&1 && { echo "FAIL plant: planted $k edit not caught"; exit 1; }
done
echo "ok import: 6 files equal faces $SHA except import lines (gpu/net.mojo: plus the recorded patch); planted code and import edits caught"

# (3) builds and runs with only gpunet and mmap
MOJO=${MOJO:-}
[ -n "$MOJO" ] || for c in "$G/../cv/.venv/bin/mojo" "$F/.venv/bin/mojo"; do [ -x "$c" ] && { MOJO=$c; break; }; done
[ -n "$MOJO" ] || block "no mojo compiler (set MOJO)"
"$MOJO" build -I src -I "$G/../mmap/src" --target-accelerator gfx1100 tests/smoke.mojo -o .work/smoke 2> .work/smoke.err || { head -20 .work/smoke.err; echo "FAIL build: tests/smoke.mojo"; exit 1; }
.work/smoke | tee .work/smoke.out
grep -q '^PASS smoke gpunet' .work/smoke.out || { echo "FAIL run: smoke printed no PASS"; exit 1; }
echo "PASS ci gpunet"
