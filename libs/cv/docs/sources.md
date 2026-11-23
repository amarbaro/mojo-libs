# Sources

mojo-cv is written from public documentation and papers, not from another library's code. The 2D ops follow
OpenCV 5.0 semantics, so cv2 5.0 is the oracle for them; the 3D ops are checked against brute force or a closed form.

## 2D vision and geometry

- OpenCV 5.0 documentation: the function pages define the semantics each op matches.
- Rublee et al. 2011 (ORB); Rosten & Drummond 2006 (FAST); Calonder et al. 2010 (BRIEF).
- Lucas & Kanade 1981; Bouguet 2000 (pyramidal LK); Farneback 2003.
- Canny 1986; Suzuki & Abe 1985 (contours); Shi & Tomasi 1994; Rother et al. 2004 (GrabCut);
  Dalal & Triggs 2005 (HOG).
- Lepetit, Moreno-Noguer, Fua 2009 (EPnP); Fischler & Bolles 1981 (RANSAC); Hartley & Zisserman, Multiple
  View Geometry; Nister 2004 (5-point); Hirschmuller 2008 (SGM); Zhang 2000 (calibration);
  Garrido-Jurado et al. 2014 (ArUco).
- Stewenius, Engels & Nister 2006, *Recent developments on direct relative orientation*, ISPRS J. 60(4):284-294,
  [doi:10.1016/j.isprsjprs.2006.03.005](https://doi.org/10.1016/j.isprsjprs.2006.03.005): the action-matrix variant
  of Nister 2004 used for `findEssentialMat`.

## Face and micro-expression ops (`hyper`)

- arXiv 2409.05396 (FacialFlowNet, decomposed facial flow), 2603.07043 (onset-referenced flow), 2601.06479 (SRFlow, Sobel-masked
  regularisation, EPE), 2310.10022 (downscale protocol), 2607.15995 (four-landmark homography), 2611.16793 (equirectangular
  remap), 2308.01700 and Ojansivu and Heikkila 2008 (LPQ), 2606.25542 and Wu et al. 2012 (Eulerian video magnification).
  Cards and the verbatim quotes: `mojo-cv-papers/cards/`. Definitions the cards leave open: [hyper.md](hyper.md).

## 3D, time and CAD

- Zobrist 1970; Meagher 1982 (octrees).
- Umeyama 1991 (least-squares similarity between point patterns).
- Mallat, A Wavelet Tour of Signal Processing; Kuglin & Hines 1975 (phase correlation).
- Koppula et al. 2024 (TAPVid-3D); Wronski et al. 2019 (handheld burst super-resolution).
- Piegl & Tiller, The NURBS Book; Khronos glTF 2.0 specification; ISO 10303-21 and the AP242 schema.
- Any continuum mechanics text for von Mises and principal stresses.

## Stock-site checks (`stockcheck`)

Methods are the published definitions, implemented from their descriptions; numpy/cv2 on the same definition is the oracle.

- Variance of the Laplacian as a focus measure: Pech-Pacheco et al. 2000; Tenengrad (Sobel gradient energy): Krotkov 1987.
- Immerkaer 1996, *Fast noise variance estimation*, CVIU 64(2): the 3x3 mask used by `noiseEst`.
- Block-edge discontinuity as JPEG blockiness: Wang, Bovik et al. 2002, *No-reference perceptual quality assessment of JPEG
  compressed images*, the 8-pixel boundary contrast idea, here as a plain boundary-to-interior difference ratio.
- dHash (Krawetz 2013) and pHash (Zauner 2010, DCT of a 32x32 reduction); the box reduction and the 1e-6 rounding of DCT
  coefficients before the median compare are ours, chosen so the hash is bit exact against the numpy oracle.
- Nothing from the PaperBrain vault: `paperbrain-ask` on no-reference IQA (BRISQUE, NIQE), perceptual hashing and
  AI-image detection returned only unrelated mathematics papers (the vault holds no image-quality literature; queries and
  answers in `.work/paperbrain.txt`). BRISQUE and NIQE were not built: both need a pretrained natural-scene model that
  is not in the repo, and the measured pixel numbers already show that technical quality does not separate Adobe's refusals.
- Calibration data: `~/Projects/gpu-media/doar-bio-stock` (128 uploaded files) with the per-file Adobe refusals in
  `~/Brain/gpu-media/doar-bio-stock/2026-11-13-adobe-review.md`; rejection reasons from `~/Projects/AssetsHQ/docs/mistakes-extracted.md`.
