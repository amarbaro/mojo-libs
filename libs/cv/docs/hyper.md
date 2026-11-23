# Hyper ops: face, micro-expression and stock-photo geometry

Twelve ops from 2023-2026 face and micro-expression papers match cv2 or a numpy definition on 34 case rows
(`tests/cases/hyper.txt`) and raise on 21 malformed inputs (`tools/malformed_check.py`). Source: `src/mojocv/hyper.mojo`.
Each op comes from a paper card in `mojo-cv-papers/cards/<arxiv id>.md`; where a card gives no formula, the op says so below.
CPU only. A GPU path was not built: every op runs in milliseconds on face-sized inputs, and the library has no MAX GPU code to extend.

`mojo-cv OP OUT IN... [k=v]`; several outputs go to `OUT`, `OUT.1`. Flows are float32 `rows x cols x 2` (u, v), frames uint8 grey.

| op | paper | inputs, options | outputs | oracle, tolerance |
|---|---|---|---|---|
| `flowDecomp` | 2409.05396 | `flow [mask] iters=1 thr=1` | residual flow = flow - affine fit; 2 x 3 float64 parameters (u = a x + b y + c, v = d x + e y + f, pixel coordinates) | numpy `lstsq`; flow max 1e-4, parameters max 1e-6 (measured 0 and 3e-15) |
| `flowStrain` | 2603.07043 | `flow` | optical strain sqrt(exx^2 + eyy^2 + 2 exy^2); flow magnitude | `numpy.gradient`; max 1e-5 (measured 0) |
| `onsetFlow` | 2603.07043 | `onset f1 f2 ... [Farneback options]` | one rows x cols x 2k float32 stack, the flow onset to frame j in channels 2j, 2j+1 | `cv2.calcOpticalFlowFarneback` per frame; max 0.03 (measured 0.023 on the frame pair 3 px away) |
| `flowEpe` | 2601.06479 | `pred gt [mask]` | 1 x 3: mean end-point error, share above 1 px, pixel count | numpy; max 1e-6 (measured 2e-16) |
| `flowReg` | 2601.06479 | `frame flow thr=40` | 1 x 3: mean smoothness loss on texture-less pixels, their share, mean Sobel magnitude | numpy + `cv2.Sobel`; max 1e-6 (measured 6e-14) |
| `downUp` | 2310.10022 | `img f=4 down=4 up=2` | INTER_AREA down by f, bicubic back to the input size | cv2 `resize` twice; max 2 levels (measured 2) |
| `getPerspectiveTransform` | 2607.15995 | `src4 dst4` (4 x 2 float64) | 3 x 3 float64 | `cv2.getPerspectiveTransform`; max 1e-6 (measured 4e-14) |
| `warpPerspective` | 2607.15995 | `img M w h inv=0 bval=0` | bilinear warp, constant border | `cv2.warpPerspective`; max 1 level (measured 1) |
| `eq2persp`, `persp2eq` | 2611.16793 | `img fov=90 yaw=0 pitch=0 w h` | pinhole view of an equirectangular picture, and back | numpy grids + `cv2.remap`; max 1 level (measured 1) |
| `lpq` | 2308.01700 | `img win=7` | codes uint8 over the valid area; normalised 256-bin histogram | numpy STFT definition; codes exact, histogram max 1e-12 (measured 0) |
| `evm` | 2606.25542 | `stack alpha=20 lo=0.05 hi=0.4 sigma=0` | stack, frames in channels | numpy loop; max 1e-3 (measured 1.5e-5, 4e-4 with sigma) |

## Timings (this box, 8 workers, best of 5, 1080p unless noted)

| op | ms | note |
|---|---|---|
| `lpq win=9` | 19 (148 before the separable pass) | 34 MB peak RSS, `heaptide` live bytes equal at 1 and 4 repeats |
| `lpq win=7` | 16 (91 before) | |
| `eq2persp` 1280 x 720 from 1024 x 512 | 12 (31 before maps ran on one core) | |
| `persp2eq` 2048 x 1024 from 1080p | 11 (31 before) | |
| `warpPerspective` 1080p | 4.4 (11.7 before); cv2 0.9 | the maps cost 4 ms, `remap` the rest |
| `downUp f=4` 1080p | 4.1; cv2 1.8 | |
| `onsetFlow` 3 frames, 270 x 480 | 127 | three Farneback runs |
| `evm` 48 x 80 x 32 | 0.56 | |
| `flowDecomp iters=3` 96 x 128 | 0.28 | |

## Definitions the cards leave open

- `flowDecomp`: a global affine model is the rigid-head stand-in. `iters` > 1 refits on the pixels whose residual is at most `thr`, so the expression flow does not drag the head fit. The paper's decomposition is a network; this is the closed-form part.
- `flowReg`: SRFlow (2601.06479) says its regularisation uses masks and gradients from Sobel operators; no formula was in the span read. This op is our reading: mean absolute forward difference of u and v on pixels whose Sobel magnitude is below `thr`.
- `lpq`: Ojansivu and Heikkila's frequencies (a, 0), (0, a), (a, a), (a, -a), a = 1/win, no decorrelation step. A part counts as positive above 1e-9, not at 0, so flat windows give code 0 in every implementation (a sum of cosines over a period is 1e-15, not 0, in floating point).
- `evm`: spatial Gaussian blur, then per pixel two first-order IIR low-passes (hi, lo), `out = in + alpha (L_hi - L_lo)` (Wu et al. 2012). The frames sit in channels, so a clip of T frames is a `rows x cols x T` file.
- `eq2persp`: yaw to the right, pitch down, pixel centres at (x + 0.5) / W of 360 degrees; longitude wraps, the poles replicate. Round trip persp2eq then eq2persp of a 480 x 270 view through a 2048 x 1024 picture: mean abs error 2.8 levels, 99th percentile 33 (two resamplings over text edges), no offset.
- `onsetFlow` reuses the existing Farneback code. At `winsize=9 levels=2 iters=2`, 0.09 % of the pixels of the `smg` pair differ from cv2 by more than 0.05 px, all in one ill-conditioned patch (up to 8 px at a flow of 18 px). The row `onset_win9` states that share; it is cv2's own sensitivity there, not a new bug.

## Not built

LightSEAD keypoints (2611.23661; needs the trained 85k weights), depth region merging (2611.23958), event contrast losses (2611.27509), the temporal-shift attention block (2406.17538; a trained layer). `evm` covers the Eulerian half of 2406.17538.
