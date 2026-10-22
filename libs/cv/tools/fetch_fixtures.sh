#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL="$ROOT/tests/real"
mkdir -p "$REAL"
PY="${MCV_PY:-$HOME/iTools/video/camera-motion/v/bin/python}"

# chessboard photos
if [ ! -d "$REAL/data/imgs/leftcamera" ]; then
  (cd "$REAL" && kaggle datasets download -d danielwe14/stereocamera-chessboard-pictures -p . --unzip)
fi
# aruco markers (svg)
if [ ! -d "$REAL/ArucoMarkers" ]; then
  (cd "$REAL" && kaggle datasets download -d crsuthikshnkumar/aruco-marker-data-set -p . --unzip)
fi

# convert 5 chessboard photos to gray .mcv
$PY - "$REAL" <<'PY'
import cv2, sys, os
real=sys.argv[1]
names=[1,10,11,12,13]
for i,n in enumerate(names):
    p=os.path.join(real,'data','imgs','leftcamera',f'Im_L_{n}.png')
    im=cv2.imread(p,cv2.IMREAD_GRAYSCALE)
    assert im is not None, p
    import importlib.util
    spec=importlib.util.spec_from_file_location('mcv', os.path.join(real,'..','..','tools','mcv.py'))
    # fallback: append tools to path
    sys.path.insert(0, os.path.join(real,'..','..','tools'))
    import mcv
    mcv.save(im, os.path.join(real, f'chess_{i}.mcv'))
    objp=__import__('numpy').zeros((11*7,3),dtype=__import__('numpy').float64)
    objp[:,:2]=__import__('numpy').mgrid[0:11,0:7].T.reshape(-1,2)
    K=__import__('numpy').array([[800,0,im.shape[1]//2],[0,800,im.shape[0]//2],[0,0,1]],dtype=__import__('numpy').float64)
    dist=__import__('numpy').zeros((5,1),dtype=__import__('numpy').float64)
    gray=im
    ok,corners=cv2.findChessboardCorners(gray,(11,7))
    assert ok
    mcv.save(objp, os.path.join(real, f'pnp_obj_{i}.mcv'))
    mcv.save(corners.reshape(-1,2).astype(__import__('numpy').float64), os.path.join(real, f'pnp_img_{i}.mcv'))
    mcv.save(K, os.path.join(real, f'pnp_K_{i}.mcv'))
    mcv.save(dist, os.path.join(real, f'pnp_d_{i}.mcv'))
# aruco markers
import subprocess
for i in range(5):
    svg=os.path.join(real,'ArucoMarkers','4x4',f'4x4_1000-{i}.svg')
    png=os.path.join(real,f'aruco_{i}.png')
    if not os.path.exists(png):
        subprocess.run(['rsvg-convert','-w','200','-h','200',svg,'-o',png],check=True)
    im=cv2.imread(png,cv2.IMREAD_GRAYSCALE)
    im2=cv2.copyMakeBorder(im,20,20,20,20,cv2.BORDER_CONSTANT,value=255)
    mcv.save(im2, os.path.join(real, f'aruco_{i}.mcv'))
# one video frame
frame=os.path.join(real,'frame0.png')
if not os.path.exists(frame):
    subprocess.run(['ffmpeg','-y','-i',os.path.expanduser('~/Videos/obs.space/2026-01-25 15-05-00.mkv'),'-vf','scale=640:360,format=gray','-frames:v','1',frame],check=True,stderr=subprocess.DEVNULL)
im=cv2.imread(frame,cv2.IMREAD_GRAYSCALE)
mcv.save(im, os.path.join(real,'frame0.mcv'))
print('fetch_fixtures: converted real inputs')
PY