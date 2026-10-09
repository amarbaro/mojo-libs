# mojo-imkit: build protocol

Rules for anyone (person, Claude, Codex) adding to imkit. `CLAUDE.md` is a symlink to this file. Read `README.md` and
`docs/DESIGN.md` first; they are the current truth about the frame, the command layout and the budgets.

## What imkit is

An immediate-mode GUI for Mojo apps, built around the idea of Dear ImGui / imgui-bundle, not ported from it. Widgets
are function calls made every frame; they append to one flat draw list; one `compose` kernel draws that list on the
GPU into an RGBA layer; the window blends the layer over the app's own frame. First consumer: fly-connectome's
engine GUI (`agent/body_engine/live.mojo -DGUI=1`, `ctl.mojo`).

## Do

**Design**
1. **Immediate mode only.** A widget is `def name(mut self, id, ...) -> interaction` (Bool, value, delta). The only
   state between frames is `hot`, `active` and what the caller passes in. State a widget needs across frames (a
   panel's position, a scroll offset) lives in a small flat table keyed by id, owned by `Ui`, allocated once.
2. **Compose before you add.** A new widget is first built from existing primitives (rect, glyph, line, tri) and
   `clickable`. A new command kind in `compose` only when no combination can draw it; then it is one branch in the
   existing kernel, documented in `docs/DESIGN.md`, never a second kernel.
3. **One body, many widgets.** Interaction goes through `clickable` (or one new generic body, e.g. `draggable`) shared
   by every widget of that kind. No copy-pasted hit testing.
4. **Theme tokens.** Colours, radii and spacing come from the constants at the top of `ui.mojo`. No literal colours
   inside a widget.
5. **App-agnostic.** Nothing in `src/imkit` knows about Kinestride, flies, brains or sockets. App wiring stays in the
   app.

**Bytes and time** (the memory-optimization contract)
6. Everything is allocated once at start: draw list, bins, counts, atlas, layer, id tables. No allocation inside
   `begin` ... `finish`, inside `compose`, or per frame in `window.poll` / `present`.
7. Fixed capacities (`NCMD`, `NBIN`, `ISRC`, any new table) overflow by **dropping and counting** (whole commands,
   never half a tile's list), never by growing or crashing; the count is readable by the app and asserted 0 in tests.
8. Name the hot path, measure before and after on the same input (`ui_test` prints compose us per launch), put the
   numbers in the commit body: `hot path: X · before A us / B KB · after C / D`. Budget: compose <= 300 us at
   1280 x 720; the whole UI <= 0.5 ms per frame.

**Mojo 1.1** (also see the skills below)
9. FFI: `OwnedDLHandle("libX.so.N").get_function[Ret]("name")(args)`; the lookup raises, so the method `raises`.
   C strings: `.as_c_string_slice().unsafe_ptr()`. Kernel arguments: `Int32`, not `Int`.
10. Struct offsets of SDL / FreeType come from an `offsetof` probe compiled against the installed headers, and are
    written into the module docstring with the library version. Never guessed, never copied from the web.
11. Inside `src/imkit`: package-relative imports (`from .font import Font`). Tests and apps: `from imkit.ui import ...`
    with `-I src`.
12. `List` / `Span` over hand-rolled pointers; `comptime` for constants; `get_defined_int` for build-time sizes.

**Checks** (nothing is done until one passed)
13. Every new widget or primitive lands with a test in `tests/` that drives it headless: scripted `Input` -> widget ->
    `finish` -> `compose` -> assert the interaction (one click per press + release, drag deltas, values) **and** a
    pixel property (coverage, alpha, colour at a known point).
14. Each test catches a **mutant**: break the feature on purpose (wrong winding, wrong sign, clear state too early),
    see the test fail, restore. Say which mutant in the commit body.
15. **Look at the picture.** `ui_test OUT.ppm` (or the app's `GUI_SHOT`) is opened and looked at before a UI change is
    called done. A pixel assert cannot tell you it looks wrong.
16. `tools/gate.sh` passes before every commit. It runs `ui_test` on the GPU through `gpu-wait`; `window_test` opens a
    real window for ~2 s, so say so to the user before running it.
17. API change (a renamed or re-shaped function, a new required argument): rebuild the consumer and run its checks,
    fly-connectome `python -m agent.body_engine.gui_check` (opens a window, ~2 min) and
    `python -m agent.body_engine.live check`, both under `gpu-wait`. Fix the consumer in the same session.

**Process**
18. One coherent unit, one commit, on `main`: conventional subject, a body that says why, the check and its numbers.
19. Docs move with the code: the README modules table and `docs/DESIGN.md` (command kinds, budgets, "Not yet") in the
    same commit as the feature.
20. A change a user can meet gets a release: `~/iTools/dev/release-note/release-note.sh new vX.Y.Z .`, fill every
    section (Verified names the checks), `check`, `tag`.
21. Board: `~/Brain/mojo/mojo-imkit/whiteboard.md`, tick the card the turn the work lands; findings into
    `~/Brain/mojo/mojo-imkit/` as dated notes.

## Do not

- **No port.** Do not copy Dear ImGui, ImPlot or any other GUI library's code or structure; take the idea, build it
  for one GPU draw list.
- **No retained mode**: no widget objects, no tree, no callbacks, no event bus.
- **No new dependencies**: no binding packages, no Python, no C shim, no bundled libraries. System `libSDL3` and
  `libfreetype` through FFI are the whole list; anything else is the user's decision first.
- **No second kernel or render pass** for the UI; no CPU rasterising of widgets.
- **No per-frame allocation**, no unbounded growth, no silent drops.
- **Do not change the 8-word command layout** (`kind, x0, y0, x1, y1, r, rgba, aux`) without updating `compose`,
  every producer and `docs/DESIGN.md` in one commit.
- **No app knowledge** in `src/imkit` (no Kinestride, fly, EngineControl names).
- **No bare GPU runs**: every GPU job goes through `gpu-wait run ... --timeout S -- cmd`.
- **No artifacts in `/tmp`**: use `.work/` (gitignored).
- **No git remote, no push.** No `Co-Authored-By` or model attribution in commits. No em dashes anywhere.
- **No "done" without a named check**: if the check did not run, write UNVERIFIED and what is missing.

## Skills to read (Codex does not load them; read the files)

- `~/Brain/Skills/own/mojo-lean/SKILL.md`: minimum-LOC Mojo, one generic over N copies.
- `~/Brain/Skills/own/mojo-nightly-lane-builder/SKILL.md`: Mojo 1.1 compile-error classes and their fixes, bug
  classes reviewers catch, gate discipline.
- `~/.claude/skills/memory-optimization/SKILL.md`: the bytes-and-seconds contract behind rules 6-8.

Name in your report which of these you read.

## Next work (from the board)

Docking (drag, resize, snap, collapse, saved layout), plots with axes, slider, text input, menus, DPI scaling.
