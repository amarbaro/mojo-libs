# Request: ops for a phone UI agent (tester swaps, game play)

From: AB-Android Play testing (Cordelette camps, 14-day tester swaps). Frames come from the phone panel
(`127.0.0.1:8740/api/frame`, JPEG, 540 to 1080 wide) or `adb exec-out screencap -p` (PNG, 1080x2340 or 2340x1080).
Today the agent taps from the Android UI tree and tesseract; both fail on games (canvas, no tree) and on dark
pages (Brave dark mode, horror games). Each item names the case that failed on 2026-11-23.

| # | op | cv2 equivalent | failed case it fixes |
|---|---|---|---|
| 1 | template match, normalized, multi-scale 0.5..2 | `matchTemplate` TM_CCOEFF_NORMED + `minMaxLoc` | find the Play "You" tab, star row, Install button without a UI tree |
| 2 | frame diff + changed-region boxes | `absdiff`, `threshold`, `findContours`, `boundingRect` | "did my tap do anything": today an `OK` reply proves nothing |
| 3 | checkbox / toggle state from a crop | mean colour in ROI, `inRange` | Cordelette ticks are not in the UI tree; current check samples one pixel |
| 4 | low-light text prep for OCR | `CLAHE`, `adaptiveThreshold`, invert | dark Google Groups page in Brave: tesseract read nothing |
| 5 | button / rounded-rect detector | `Canny` + `findContours` + `approxPolyDP` | game HUD buttons ("Interact", "Drop") in landscape games |
| 6 | dense optical flow, mean vector | `calcOpticalFlowFarneback` | confirm a swipe moved the camera in a 3D game |
| 7 | scene brightness histogram | `calcHist` on V channel | review note "scene too dark" backed by a number |

Wanted shape: a CLI that takes a frame path (and template path for 1) and prints one line per hit:
`x y w h score` normalized 0..1, so the agent can pass `x y` straight to `/api/cmd tap`.
Priority: 1, 2, 3 first; they unblock every app in a camp round.
