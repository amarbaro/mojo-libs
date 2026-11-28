#!/usr/bin/env bash
# tests/dupsig.sh: viewSig and sigPairs on planted ortho pictures and geometry rows. A brown L-shaped object A; B = A with another hue,
# 80 % size, shifted (a colour variant: view pair, large colour distance); E = A's picture with 40 times the triangles (a LOD: view
# pair); N = A with a notch (look pair: 97 % silhouette, same textures, same colour); C = a star (no pair); D = A with black stripes through it (no pair: silhouette differs); two rows with no picture
# whose triangles, vertices and box agree after a unit change and share a texture (geo pair), a third with another texture size (none).
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${MCV_BIN:-.bin/mojo-cv}; w=.work/dupsig-test; rm -rf "$w"; mkdir -p "$w"
[ -x "$bin" ] || { echo "FAIL setup: $bin missing"; exit 1; }
grad="gradient:#d08040-#301808"
magick -size 512x512 xc:black -fill white -draw 'polygon 100,200 420,200 420,420 330,420 330,300 100,300' "$w/mask.png"
magick -size 512x512 $grad "$w/mask.png" -compose Multiply -composite -depth 8 "$w/A.png"
magick "$w/A.png" -modulate 100,100,60 -resize 80% -background black -gravity SouthEast -extent 512x512 -depth 8 "$w/B.png"
cp "$w/A.png" "$w/E.png"
magick "$w/A.png" -fill black -draw 'rectangle 380,200 420,240' -depth 8 "$w/N.png"
magick -size 512x512 xc:black -fill white -draw 'polygon 256,60 300,200 450,200 330,290 375,440 256,350 137,440 182,290 62,200 212,200' "$w/smask.png"
magick -size 512x512 $grad "$w/smask.png" -compose Multiply -composite -depth 8 "$w/C.png"
magick "$w/A.png" -fill black -draw 'rectangle 0,215 512,235' -draw 'rectangle 0,255 512,275' -draw 'rectangle 160,0 180,512' -draw 'rectangle 250,0 270,512' -depth 8 "$w/D.png"
for n in A B C D E N; do printf '%s\t%s\n' "$PWD/$w/$n.png" view; done > "$w/list.tsv"
MCV_OP=viewSig MCV_BIN=$bin scripts/mcv-visualcheck -j 2 -c 3 "$w/sig.tsv" "$w/list.tsv"
# id tris verts bx by bz tex texpx then the picture columns, or "-" x6
geo() { case $1 in A) echo "5000 3000 3 1 2";; B) echo "9000 5000 3 1 2";; D) echo "7000 4000 3 1 2";; C) echo "800 500 2 2 2";; E) echo "200000 100000 3 1 2";; N) echo "6000 3500 3 1 2";; esac; }
{
  for n in A B C D E N; do
    set -- $(geo $n)
    sig=$(awk -F'\t' -v n="$PWD/$w/$n.png" '$1 == n { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' "$w/sig.tsv")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t1\t1024\t%s\n' "$n" "$1" "$2" "$3" "$4" "$5" "$sig"
  done
  printf 'F\t1000\t600\t1\t2\t3\t1\t1024\t-\t-\t-\t-\t-\t-\n'
  printf 'G\t1010\t605\t10\t20.1\t30\t1\t1024\t-\t-\t-\t-\t-\t-\n'
  printf 'H\t1000\t600\t1\t2\t3\t1\t512\t-\t-\t-\t-\t-\t-\n'
} > "$w/in.tsv"
"$bin" sigPairs "$w/pairs.tsv" "$w/in.tsv"
fail=0
# check NAME EXPECTED_COUNT AWK_COUNT_PROGRAM
check() { local n; n=$(awk -F'\t' "$3" "$w/pairs.tsv"); if [ "$n" -eq "$2" ]; then echo "PASS $1"; else echo "FAIL $1: $n rows, expected $2"; fail=1; fi; }
check colour-variant 1 '$1 == "A" && $2 == "B" && $3 == "view" && $7 > 40 { n++ } END { print n + 0 }'
check lod-twin 1 '$1 == "A" && $2 == "E" && $3 == "view" && $7 < 1 { n++ } END { print n + 0 }'
check look-notch 2 '$3 == "look" && ($1 == "N" || $2 == "N") && ($1 == "A" || $2 == "A" || $1 == "E" || $2 == "E") { n++ } END { print n + 0 }'
check geo-twin 1 '$1 == "F" && $2 == "G" && $3 == "geo" { n++ } END { print n + 0 }'
check star-stripes-texture-unpaired 0 '$1 ~ /^[CDH]$/ || $2 ~ /^[CDH]$/ { n++ } END { print n + 0 }'
check pair-count 6 'END { print NR }'   # A-B, A-E, B-E (view), A-N, E-N (look) and F-G (geo)
exit $fail
