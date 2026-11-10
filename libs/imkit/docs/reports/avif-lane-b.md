## VERDICT
PASS for lane B's own checks (UNVERIFIED against pixels: `tests/avif_yuv_test.sh` is the real judge and needs lane A's integration).
- `tests/av1recon_test.sh`: PASS, 17/17 mutants killed. Hand-computed DC blocks 4..64, identity 4 and 16, WHT, dqDenom, 0xFFFFFF mask, quantizer matrix (luma and chroma), get_qindex rules, saturation blocks from an independent Python emulation, and a float oracle of the unnormalized transforms over 579 size/type cases (all 19 sizes, every legal tx type, flips, 2:1 rect scaling): worst |int - float| = 1.
- `tests/av1ipred_test.sh`: PASS, 21/21 mutants killed. Hand-computed 4x4 and 8x8 blocks (DC with all neighbour combinations, V, H, Paeth with ties, SMOOTH/_V/_H, D45, D203, 8x8 smooth/DC), palette, guards, and 750 vectors (600 intra, 150 CFL) from `tools/av1ipred_oracle.py` (a separate transliteration of the spec in Python, tables parsed from the spec text, so it also checks the generated `Tables`): block equal, no stray write in any plane.
- Skills loaded: avif-lane, mojo-syntax, mojo-lean, mojo-nightly-lane-builder, memory-optimization, mojo-proptest. (mojo-proptest not used: the oracle vectors are a fixed-seed differential, which replays by seed; no shrinking needed.)

## Commits (branch lane-avif-b)
- c576adf feat(avif): av1recon dequant and inverse transforms (7.12, 7.13), gated
- 6ee6eaa feat(avif): av1ipred intra, palette and chroma-from-luma prediction (7.11), gated
- 60a66c1 docs(rules): lane B recon and intra mistakes

## API (what lane A calls)
`from imkit.av1recon import ReconInput, reconstruct`, `from imkit.av1ipred import IntraInput, predict_intra, predict_palette, predict_chroma_from_luma`.
- `reconstruct(mut frame, tables, inp: ReconInput, plane, x, y, tx_size, tx_type, quant: Span[Int32,_], eob)`. `quant` needs at least `min(w,32) * min(h,32)` entries, row-major, zeros where not coded (the draft wrongly gated on `index < eob`; `eob` is only used for `eob == 0` early return and a range check). `ReconInput` fields are documented in its docstring: set per block `bit_depth, lossless, segment_id, base_q_idx, delta_q_present, current_qindex, seg_feature_enabled/data [seg*8+feature], delta_q_y_dc/u_dc/v_dc/u_ac/v_ac, using_qmatrix, seg_qm_level [plane*8+seg]`. `lossless` requires TX_4X4.
- `predict_intra(mut frame, tables, inp: IntraInput, plane, x, y, have_left, have_above, have_above_rt, have_below_lft: Bool, mode, log2w, log2h)`. `IntraInput` (documented in its docstring): `mi_cols, mi_rows, angle_delta_y, angle_delta_uv, use_filter_intra, filter_intra_mode, enable_intra_edge_filter, filter_type`. Lane A computes `filter_type` = spec `get_filter_type(plane)` (7.11.2.8; needs YModes/UVModes/RefFrames). `mode` is 0..12 (UV_CFL_PRED 13 raises; call `predict_chroma_from_luma` after a DC prediction).
- `predict_palette(...)` and `predict_chroma_from_luma(mut frame, plane, start_x, start_y, tx_size, alpha, max_luma_w=-1, max_luma_h=-1)` as frozen.

## Requests to lane A / boss
1. CFL needs MaxLumaW / MaxLumaH (spec 5.11.35: set after each luma transform block as `startX + stepX*4`, `startY + stepY*4`), which the frozen signature cannot carry. I added two defaulted trailing arguments, call-compatible with the frozen form; pass them. With the default (-1) the luma plane size is used, which is wrong at frame edges when a luma block overhangs the visible area.
2. Planes must be allocated at least `MiCols*4 x MiRows*4` (chroma: shifted by subsampling). Both lanes' writes are clipped to the plane (overhanging blocks are normal; samples outside are never read back), edge reads stay inside MiCols*4 and raise `plane smaller than ...` otherwise. A block starting outside the plane raises.
3. `src/imkit/av1state.mojo` (lane A): `tx_width`, `tx_height`, `tx_width_log2`, `tx_height_log2` do not compile (`cannot materialize comptime value of type Array[Int, 19] to runtime`), so `av1recon` does not import them (it reads `Tables`). Fix with `materialize[TX_WIDTH]()[t]` or take `Tables`.
4. Generator owner (`tools/av1_tables.mojo`): `Tables` lacks `Sm_Weights_Tx_4x4` and `Sm_Weights_Tx_8x8` (spec 10, `{255,149,85,64}` and `{255,197,146,105,73,50,37,32}`). `av1ipred.sm_weight` carries them locally, checked by the oracle (which parses them from the spec text); drop the local copy when the generator emits them.
5. have_* flags are `Bool`. Lane A calls `reconstruct` for every transform block with `eob > 0`; `eob == 0` is a no-op.

## Measured (hot path, 8-bit, 128x128 plane, one thread, cold `Tables` excluded)
reconstruct DCT_DCT with 6 coefficients: 4x4 0.68 us (42.6 ns/px), 8x8 1.78 us (27.8), 16x16 7.3 us (28.4), 32x32 33 us (32.6), 64x64 134 us (32.7). predict_intra D45 with edge filter: 4x4 0.24 us (15 ns/px), 8x8 0.76 us (12), 16x16 1.8 us (6.9), 32x32 5.8 us (5.7). Peak RSS of the bench 14 MB including `Tables()`. Not optimized further: all-zero rows are skipped (exact, every 1D transform maps 0 to 0); the next lever, if the pixel gate's wall time matters, is a per-call scratch instead of the `List` copies in `dct_permute`/`adst_*_permute`.

## Not verified (named)
- Overflow behaviour beyond the saturation blocks tested (Hadamard clip at row range, ADST butterfly range): the spec makes it a conformance requirement, no valid stream exercises it.
- 4:2:2 / 4:4:0 chroma and 12-bit CFL are exercised by the oracle vectors only for sub (0,0), (1,1), (1,0) and bd 8, 10 (intra: also 12).
- Any real bitstream. The pixel gate is the judge; send mismatch reports with (plane, x, y, tx_size, tx_type | mode, flags) and I will bisect against the oracle.
