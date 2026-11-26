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
