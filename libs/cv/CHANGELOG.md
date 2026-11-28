# Changelog

Full notes in `docs/releases/`. Newest first. Format: the release-note template.

- Unreleased: `visualCheck` adds `blank`, `seam`, `stretch` and `plain` (texdefect): the share of near-uniform light grey or white on the object, straight textured/blank boundaries inside it, one-direction stretch of the fine texture, and the share that is flat in any colour; [docs/visualcheck.md](docs/visualcheck.md)
- Unreleased: `viewSig` and `sigPairs`: duplicate signatures of 3D assets from the fitted ortho view (silhouette and shading grids, colour apart) and the geometry numbers; rules `view`, `geo`, `look`, [docs/dupsig.md](docs/dupsig.md)
- Unreleased: `visualCheck` and `scripts/mcv-visualcheck`: colour spread, inner detail, silhouette complexity, fill and a flat-shaded-primitive score per picture, with a verdict for 3D listing pictures (test half: bad precision 0.96, recall 0.88 on store previews), [docs/visualcheck.md](docs/visualcheck.md)
- Unreleased: `screenParse` reads each text line with `screen-ocr` (RapidOCR) instead of tesseract; `lang=` is accepted and ignored. fs-screen 22/22.
- Unreleased: `hyper` ops from 2023-2026 face and micro-expression papers (facial flow decomposition, optical strain, onset flow, EPE, Sobel-masked flow loss, downscale protocol, landmark homography, equirectangular remap, LPQ, Eulerian magnification), [docs/hyper.md](docs/hyper.md)
- Unreleased: mojo-supervision merged in as the second package (`src/supervision`, 3308 rows against Python supervision); one `scripts/ci.sh` runs both suites; the supervision history is kept
- [v0.1.5](docs/releases/v0.1.5.md) (2026-11-08): uint8 linear resize bit exact with cv2, Line2 first endpoint
- [v0.1.4](docs/releases/v0.1.4.md) (2026-11-08): packaging: compiler pin to build minor
- [v0.1.3](docs/releases/v0.1.3.md) (2026-11-07): docs: CHANGELOG names no home path
- [v0.1.2](docs/releases/v0.1.2.md) (2026-11-04): StereoSGBM at 1080p in 1.5 GB, cvtColor row overrun and malformed-input crashes fixed
- [v0.1.1](docs/releases/v0.1.1.md) (2026-10-29): builds on the stable Mojo 1.2.0 and MAX 26.7.0 release
- [v0.1.0](docs/releases/v0.1.0.md) (2026-10-26): first public release, OpenCV-style 2D ops, calibration and 3D/CAD helpers in Mojo, every op checked row by row against cv2 5.0 or an exact oracle
