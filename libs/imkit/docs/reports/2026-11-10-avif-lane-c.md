## VERDICT

PASS on lane C's own checks; UNVERIFIED against a pixel oracle (none until lane A integrates, `tests/avif_yuv_test.sh` is the judge).
Checked: `tests/av1filter_test.sh` -> `PASS av1filter`; `tests/av1grain_test.sh` -> `PASS av1grain` and `PASS av1grain parse: 118 fields equal ffmpeg trace_headers`.
Skills loaded at the boss's request: avif-lane, mojo-syntax, mojo-lean, mojo-nightly-lane-builder, memory-optimization, mojo-proptest (the last unused: every check is a pinned case, not a property).

Branch `lane-avif-c`, worktree `~/Projects/mojo/mojo-imkit-lanes/avif-c`. No push, base branch untouched.

## Commits

```
788887d feat(avif): AV1 deblocking loop filter (spec 7.14) with hand-computed checks
89e4f64 feat(avif): AV1 CDEF (spec 7.15) with oracle-pinned checks
576454f feat(avif): AV1 loop restoration (spec 7.17) with oracle-pinned checks
ef0f992 feat(avif): film grain params parser (5.9.30) and synthesis (7.18.3)
8c9e6a4 docs(rules): lane C mistakes that cost a round
```

## API (all Mojo 1.2, `.venv/bin/mojo`; lists are flat, index `row * stride + col`)

| call | module | input struct |
|---|---|---|
| `loop_filter(mut frame, inp: LfInput) raises` | `av1lf` | `LfInput(mi_rows, mi_cols, frame_width, frame_height, num_planes)` |
| `cdef(mut frame, pre: Frame, inp: CdefInput) raises` | `av1cdef` | `CdefInput(mi_rows, mi_cols)` |
| `loop_restoration(mut frame, cdef_out, pre_cdef, inp: LrInput) raises` | `av1lr` | `LrInput(frame_height, upscaled_width, sub_x, sub_y, num_planes, uses_lr, frame_restoration_type, loop_restoration_size)` |
| `parse_film_grain_params(mut b: Bits, mono_chrome: Bool, subsampling_x: Bool, subsampling_y: Bool) raises -> FilmGrainParams` | `av1grain` | starts at the `apply_grain` bit (caller checked present / show_frame) |
| `apply_film_grain(src: Frame, params, tables: Tables, matrix_coefficients: Int) raises -> Frame` | `av1grain` | returns a grained copy |

Field layouts (lane A fills them; comments in each struct are the contract):
- `LfInput`: `loop_filter_level[4]`, `loop_filter_sharpness`, `loop_filter_delta_enabled`, `loop_filter_ref_deltas[8]` (defaults 1,0,0,0,-1,0,-1,-1), `loop_filter_mode_deltas[2]`, `delta_lf_multi`, `seg_feature_enabled/data[segment*8+feature]` (same as FrameHeader), per 4x4 luma unit `mi_sizes skips ref_frames(ref 0) y_modes segment_ids` (UInt8/Int8), `delta_lfs` (4 per unit), `lf_tx_sizes[plane]` indexed `(row>>sub_y)*mi_cols+(col>>sub_x)`.
- `CdefInput`: `cdef_damping` (= cdef_damping_minus_3 + 3), the four strength lists (8 each, sec strength 3 already turned into 4), `cdef_idx` per 64x64 block (index `(row>>4)*cdef_stride+(col>>4)`, -1 = skip), `skips` per unit.
- `LrInput`: per plane `lr_type` (0 none, 1 Wiener, 2 SGR), `lr_wiener` (6 per unit: vertical 3 then horizontal 3), `lr_sgr_set`, `lr_sgr_xqd` (2 per unit); unit counts are computed in `__init__` (`unit_rows`, `unit_cols`).

## Requests to lane A (and the boss)

1. Plane geometry. `loop_filter`, `cdef` need planes of at least MiCols*4 x MiRows*4 luma samples (chroma `>> sub`); both raise `plane too small` otherwise. The filters read decoded samples past the visible edge, so reconstruct into padded planes, run LF, CDEF, LR on them, then crop to FrameWidth x FrameHeight (UpscaledWidth) BEFORE `apply_film_grain` (it takes w, h from `planes[0]`) and before the y4m compare. `cdef`: `frame` and `pre` same geometry; `loop_restoration`: all three frames same geometry, and it overwrites `frame` with a copy of `cdef_out` first.
2. `src/imkit/av1state.mojo` does not build on the toolchain in `.venv` at base commit 7a29f3c: `block_width`, `block_height`, `tx_width`, `tx_height`, `subsampled_size` return indexes of `comptime` Arrays (`cannot materialize comptime value of type 'Array[Int, 22]'`, lines 236, 240, 252, 256, 312). Fix with `materialize[...]()` or `global_constant`. Lane C does not import `av1state` for that reason.
3. Not done here, yours to decide: superres upscaling (LR takes frames already at UpscaledWidth), which frames skip each filter (spec 7.4 wrap-up: lossless, intrabc, enable_cdef), `av1obu.parse_film_grain` still consumes and drops the fields: call `parse_film_grain_params` from `parse_frame_header` and keep the struct in `FrameHeader`.
4. `Skips` must be what 7.15 reads (per 4x4 unit); `ref_frames` holds RefFrames[][][0] with intrabc stored as INTRA_FRAME (0).

## Checks (pasted)

```
$ tests/av1filter_test.sh
PASS av1filter
$ tests/av1grain_test.sh
PASS av1grain
PASS av1grain parse: 118 fields equal ffmpeg trace_headers
```

What they hold:
- Loop filter (`av1filter_test.mojo`): flat 4:2:0 frame stays flat; a 100 | 110 step through the 4-tap, 8-tap, 14-tap luma filters and the 6-tap chroma filter at lvl 10 gives hand-worked rows (102 104 | 106 108; 101 103 104 | 106 108 109; ...), 10-bit narrow, hev, mask reject, level 0, segment feature, ref delta with shift, previous-unit level fallback. 3 mutants (nShift, prev-unit, thresh) fail it.
- CDEF: flat stays flat; stripe patterns return directions 0, 4, 2, 6 with oracle variances; 7 frames (8/10 bit, 4:2:0, 4:2:2, 4:4:4, var_str 2/12/13) pinned by checksum from `tools/av1_cdef_oracle.py`. 7 of 9 mutants fail; two survive: the `var_str` cap (12 vs 11 or 13) and the +8 rounding of `priStr` is covered only by the var_str 2 frame. Open.
- Loop restoration: 5 frames (8 and 10 bit, 4:2:0 / 4:2:2 / 4:4:4, odd sizes, stripes, units, Wiener, all 16 SGR sets used by the unit pattern) pinned by `tools/av1_lr_oracle.py`, which follows the spec's per-4x4-block text while the decoder walks stripe x unit regions. 6 of 7 mutants fail; `unit_row` +8 is equivalent.
- Film grain: LFSR first 8 outputs for seed 1 worked by hand (0x8000 0x4000 0x2000 0x1000 0x8800 0x4400 0x2200 0x1100 at 16 bits, 1024 512 256 128 1088 544 272 136 at 11 bits); 4 synthesis configs pinned by `tools/av1_grain_oracle.py` (reads Gaussian_Sequence from the spec text); parse equals ffmpeg trace_headers on `.work/avif/grain.obu` (`aomenc --film-grain-test=1`, 14 luma, 8 cb, 9 cr points, lag 2). 8 of 8 mutants fail.
- The oracles are my own transcription of the spec text, so a spec misreading shared by both would pass; the real judge is `tests/avif_yuv_test.sh`.

## Bytes and seconds (memory-optimization)

Hot path: whole-frame filters. Input: 1024x1024 4:2:0 8-bit, `.work/av1f/bench.mojo`, one run: loop_filter 11 ms, cdef 124 ms, loop_restoration 68 ms, apply_film_grain 18 ms; 0.24 s and 25.7 MB peak RSS for the whole process. Not tuned: the per-4x4 loop filter edge walk, CDEF's per-tap table lookups and `Tables()` (0.7 ms, built once per call) are the first candidates if a fixture is slow. No before number: nothing existed.
