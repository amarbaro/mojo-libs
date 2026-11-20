#!/usr/bin/env bash
# ruler: tapeScale on a drawn tape with a known scale (cm ticks one edge, inch ticks the other), both orientations.
# Pass = px/cm within 0.5 % of the drawn value. Usage: tests/ruler.sh [PPCM]
set -euo pipefail
cd "$(dirname "$0")/.."
B=.bin/mojo-cv; W=.work/ruler; mkdir -p "$W"
P=${1:-47.3}
[ -x "$B" ] || { echo "FAIL build: $B missing"; exit 1; }
tomcv() { # IMG OUT: RGB uint8 .mcv
  local w h; read -r w h < <(magick "$1" -format '%w %h\n' info:)
  { perl -e 'print pack("a4VVvv", "MCV1", @ARGV, 3, 0)' "$h" "$w"; magick "$1" -depth 8 rgb:-; } > "$2"; }
draw=$(awk -v p="$P" 'BEGIN{ h=2.2*p; b=10+h;
  for(i=0;i*p/10<1900;i++){x=40+i*p/10; l=((i%10==0)?.40:(i%5==0)?.28:.16)*h; printf "line %.2f,%.1f %.2f,%.1f ",x,b-l,x,b}
  q=2.54*p/16; for(i=0;i*q<1900;i++){x=40+i*q; l=((i%16==0)?.40:(i%8==0)?.30:(i%4==0)?.22:.12)*h; printf "line %.2f,10 %.2f,%.1f ",x,x,10+l}}')
bot=$(awk -v p="$P" 'BEGIN{printf "%d", 10+2.2*p}')
magick -size 2000x400 xc:'#7a6a55' -fill '#f2d21b' -draw "rectangle 20,10 1980,$bot" -stroke black -strokewidth 2 -draw "$draw" "$W/h.png"
magick "$W/h.png" -rotate 90 "$W/v.png"
for o in h v; do
  tomcv "$W/$o.png" "$W/$o.mcv"
  "$B" tapeScale "$W/$o.out.mcv" "$W/$o.mcv"
  got=$(od -A n -t f8 -j 16 -N 8 "$W/$o.out.mcv" | tr -d ' ')
  awk -v g="$got" -v p="$P" -v o="$o" 'BEGIN{e=(g-p)/p*100; if(e<0)e=-e; printf "%s px/cm %.3f (drawn %.3f, err %.2f%%)\n",o,g,p,e; exit !(e<0.5)}' || { echo "FAIL tapeScale $o"; exit 1; }
done
# hint: a rough scale 20 % off must still land on the drawn value
"$B" tapeScale "$W/h.out.mcv" "$W/h.mcv" hint=$(awk -v p="$P" 'BEGIN{print p*1.2}')
got=$(od -A n -t f8 -j 16 -N 8 "$W/h.out.mcv" | tr -d ' ')
awk -v g="$got" -v p="$P" 'BEGIN{e=(g-p)/p*100; if(e<0)e=-e; printf "hint px/cm %.3f (err %.2f%%)\n",g,e; exit !(e<0.5)}' || { echo "FAIL tapeScale hint"; exit 1; }
echo "OK ruler"
