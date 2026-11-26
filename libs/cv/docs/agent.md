# Agent perception: mojo-cv for phone, web and desktop agents

Goal: an agent driving a phone (adb/scrcpy), a web page (CDP) or a desktop (CUA) asks mojo-cv cheap questions about a frame
instead of sending every full screenshot to a model: where are the elements, did my action change anything, has the screen settled.

Existing ops (`src/mojocv/screen.mojo`): `screenParse` (widget boxes, roles, OCR text) and `screenStuck` (change between two
captures). Until now they were checked only on the synthetic and OCR-drafted fs-h2 set (`docs/fs-h2.md`). This lane checks them
against real ground truth: the Android UI tree (`uiautomator dump`) and later the DOM.

## Data

Recorder `tools/agent/rec.sh SERIAL OUT N`: for each step a screenshot, the UI tree, one tap on a random clickable node
(blocked packages: dialer, messages, Play Store, payment; foreground outside the allowlist → back to Settings), then the
frame after. Output `.work/cv-agent/<phone>/step_NNNN.{png,xml,act}`. Test phone: A70
(`~/Brain/hardware/Android/2026-11-26-a70-mt6580-profile.md`).

## Gates

| gate | truth | metric |
|---|---|---|
| G1 boxes | UI-tree nodes with `clickable="true"` | recall and precision at IoU 0.5 |
| G2 change | UI tree differs between before and after | agreement of `screenStuck` progress |
| G3 settle | frames after a tap | time until two frames are equal |

## Steps

1. Recorder + G1/G2 scorer (`tools/agent/score.sh`). Baseline numbers on the A70.
2. Fix `screenParse` where it fails on real phones.
3. `screenSettle` op (G3) and a numbered grid overlay for model prompts.
4. Web: DOM boxes as truth through the devtools MCP.
5. Desktop: no free truth; test what phone and web tuned.

## Log

- 2026-11-26: A70 smoke: screencap 1.5 s, dump 3.2 s, 42 nodes / 16 clickable on the home screen.
  `screenParse ocr=0` 0.04 s, 0 elements: the launcher wallpaper is a photo, and the parser needs flat colour.
- 2026-11-26 baseline, A70 run r1 (150 steps, seed 7, 7 local apps; `.work/cv-agent/a70/r1`, `score.sh`):

  | gate | value |
  |---|---|
  | G1 truth / parsed | 1146 clickable nodes / 5552 parsed elements (4.8x over-segmentation) |
  | G1 recall at IoU 0.5 | 0.154 (boxes are glyphs and grid cells, not the widget) |
  | G1 hit-recall | 0.891 (a parsed centre lies inside the truth box: tappable) |
  | G1 parsed centres inside a truth box | 0.576 |
  | G2 agreement with pixel change, default minfrac 0.005 | 0.853; all misses are small changes, never a false progress |

  Per app, hit-recall 0.80 (file manager) to 1.00; IoU recall 0.05 (calculator keys) to 0.67 (sound recorder).
- 2026-11-26 G2 minfrac sweep (r1, truth = any pixel changed) and idle noise control (`idle.sh`, 30 no-input pairs 1.7 s apart):

  | minfrac | caught of 125 changes | false progress of 30 idle |
  |---|---|---|
  | 0.005 (default) | 103 | 0 |
  | 0.001 | 112 | 0 |
  | 0.0005 | 120 | 0 |
  | 0.0001 | 125 | 2 (calendar, file manager) |

  Agent preset: `minfrac=0.0005`. The default stays (the fs-screen rows pin it); N is small, so re-check on a second phone.
  Next: G1 over-segmentation. Merge a text line into the clickable widget around it, and drop grid cells with no ink.
