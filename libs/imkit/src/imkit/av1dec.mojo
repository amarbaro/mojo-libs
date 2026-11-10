"""AV1 intra frame decode: parse every tile (av1tile), replay prediction and reconstruction in decode order (av1ipred,
av1recon, av1intrabc), then the frame filters (av1lf, av1cdef, av1lr) and film grain (av1grain). Spec 5.11 / 7.11 / 7.12 / 7.14
to 7.18, order of 7.4 (decode_frame_wrapup).

The parse never reads a reconstructed sample, so it runs first and leaves frame-wide grids plus decode-order block and
transform records in a TileState; replay then follows the spec's transform_block order exactly."""
from imkit.av1obu import Av1Stream, Bits
from imkit.av1tab import Tables
from imkit.av1frame import Frame
from imkit.av1state import (
    TileState, BlockInfo, TxRec, DC_PRED, UV_CFL_PRED, SMOOTH_PRED, SMOOTH_V_PRED, SMOOTH_H_PRED, INTRA_FRAME, PAD,
    MAX_SEGMENTS, SEG_LVL_MAX, RESTORE_NONE, NUM_4X4_WIDE, NUM_4X4_HIGH, TX_WIDTH, TX_HEIGHT, TX_WIDTH_LOG2,
    TX_HEIGHT_LOG2, MAX_TX_SIZE_RECT, BLOCK_WIDTH, BLOCK_HEIGHT, subsampled_size,
)
from std.builtin.globals import global_constant
from imkit.av1tile import parse_frame
from imkit.av1recon import reconstruct, ReconInput
from imkit.av1ipred import predict_intra, predict_palette, predict_chroma_from_luma, IntraInput
from imkit.av1intrabc import predict_intrabc
from imkit.av1lf import loop_filter, LfInput
from imkit.av1cdef import cdef, CdefInput
from imkit.av1lr import loop_restoration, LrInput
from imkit.av1grain import parse_film_grain_params, apply_film_grain


def is_smooth(ts: TileState, row: Int, col: Int, plane: Int) -> Bool:
    var idx = ts.at(row, col)
    var mode: Int
    if plane == 0:
        mode = ts.y_modes[idx]
    else:
        if ts.ref_frames[idx * 2] > INTRA_FRAME:
            return False
        mode = ts.uv_modes[idx]
    return mode == SMOOTH_PRED or mode == SMOOTH_V_PRED or mode == SMOOTH_H_PRED


def get_filter_type(ts: TileState, b: BlockInfo, plane: Int) -> Int:
    """7.11.2.8."""
    var above_smooth = False
    var left_smooth = False
    if b.avail_u if plane == 0 else b.avail_u_chroma:
        var r = b.mi_row - 1
        var c = b.mi_col
        if plane > 0:
            if ts.sub_x == 1 and (b.mi_col & 1) == 0:
                c += 1
            if ts.sub_y == 1 and (b.mi_row & 1) == 1:
                r -= 1
        above_smooth = is_smooth(ts, r, c, plane)
    if b.avail_l if plane == 0 else b.avail_l_chroma:
        var r = b.mi_row
        var c = b.mi_col - 1
        if plane > 0:
            if ts.sub_x == 1 and (b.mi_col & 1) == 1:
                c -= 1
            if ts.sub_y == 1 and (b.mi_row & 1) == 0:
                r += 1
        left_smooth = is_smooth(ts, r, c, plane)
    return 1 if (above_smooth or left_smooth) else 0


def u16s(a: List[Int]) -> List[UInt16]:
    var r = List[UInt16]()
    for i in range(len(a)):
        r.append(UInt16(a[i]))
    return r^


def replay_block(ts: TileState, tables: Tables, mut frame: Frame, mut rin: ReconInput, mut iin: IntraInput, bi: Int) raises:
    ref b = ts.blocks[bi]
    rin.segment_id = b.segment_id
    rin.lossless = b.lossless
    rin.current_qindex = b.current_qindex
    iin.angle_delta_y = b.angle_delta_y
    iin.angle_delta_uv = b.angle_delta_uv
    iin.use_filter_intra = b.use_filter_intra
    iin.filter_intra_mode = b.filter_intra_mode
    var max_luma_w = 0
    var max_luma_h = 0
    if b.use_intrabc:
        for plane in range(1 + (2 if b.has_chroma else 0)):
            var sx = ts.sub_x if plane > 0 else 0
            var sy = ts.sub_y if plane > 0 else 0
            # the halved block, never BLOCK_INVALID: a tall 4:2:2 block still has a chroma prediction
            var w4 = max(global_constant[NUM_4X4_WIDE]()[b.mi_size] >> sx, 1)
            var h4 = max(global_constant[NUM_4X4_HIGH]()[b.mi_size] >> sy, 1)
            predict_intrabc(frame, plane, (b.mi_col >> sx) * 4, (b.mi_row >> sy) * 4, w4 * 4, h4 * 4, b.mv_row, b.mv_col,
                            ts.mi_cols, ts.mi_rows)
    var pal_y = u16s(b.palette_y)
    var pal_u = u16s(b.palette_u)
    var pal_v = u16s(b.palette_v)
    for ti in range(b.tx_first, b.tx_end):
        ref t = ts.txs[ti]
        var plane = t.plane
        if not b.is_inter:
            var log2w = global_constant[TX_WIDTH_LOG2]()[t.tx_size]
            var log2h = global_constant[TX_HEIGHT_LOG2]()[t.tx_size]
            if (plane == 0 and b.palette_size_y > 0) or (plane != 0 and b.palette_size_uv > 0):
                if plane == 0:
                    predict_palette(frame, plane, t.start_x, t.start_y, t.x, t.y, t.tx_size, Span(pal_y),
                                    Span(ts.color_maps)[b.map_y_off:], global_constant[BLOCK_WIDTH]()[b.mi_size])
                else:
                    predict_palette(frame, plane, t.start_x, t.start_y, t.x, t.y, t.tx_size,
                                    Span(pal_u) if plane == 1 else Span(pal_v), Span(ts.color_maps)[b.map_uv_off:], b.map_uv_stride)
            else:
                var is_cfl = plane > 0 and b.uv_mode == UV_CFL_PRED
                var mode = b.y_mode if plane == 0 else (DC_PRED if is_cfl else b.uv_mode)
                iin.filter_type = get_filter_type(ts, b, plane)
                predict_intra(frame, tables, iin, plane, t.start_x, t.start_y, t.have_left, t.have_above,
                              t.have_above_rt, t.have_below_lft, mode, log2w, log2h)
                if is_cfl:
                    predict_chroma_from_luma(frame, plane, t.start_x, t.start_y, t.tx_size,
                                             b.cfl_alpha_u if plane == 1 else b.cfl_alpha_v, max_luma_w, max_luma_h)
            if plane == 0:
                max_luma_w = t.start_x + (global_constant[TX_WIDTH]()[t.tx_size] >> 2) * 4
                max_luma_h = t.start_y + (global_constant[TX_HEIGHT]()[t.tx_size] >> 2) * 4
        if t.eob > 0:
            var n = min(32, global_constant[TX_WIDTH]()[t.tx_size]) * min(32, global_constant[TX_HEIGHT]()[t.tx_size])
            reconstruct(frame, tables, rin, plane, t.start_x, t.start_y, t.tx_size, t.tx_type,
                        Span(ts.quant_pool)[t.quant_off : t.quant_off + n], t.eob)


def recon_input(st: Av1Stream) -> ReconInput:
    var r = ReconInput()
    r.bit_depth = st.seq.bit_depth
    r.base_q_idx = st.frame.base_q_idx
    r.delta_q_present = st.frame.delta_q_present
    r.seg_feature_enabled = st.frame.seg_feature_enabled.copy()
    r.seg_feature_data = st.frame.seg_feature_data.copy()
    r.delta_q_y_dc = st.frame.delta_q_y_dc
    r.delta_q_u_dc = st.frame.delta_q_u_dc
    r.delta_q_v_dc = st.frame.delta_q_v_dc
    r.delta_q_u_ac = st.frame.delta_q_u_ac
    r.delta_q_v_ac = st.frame.delta_q_v_ac
    r.using_qmatrix = st.frame.using_qmatrix
    return r^


def seg_qm_levels(ts: TileState, mut r: ReconInput):
    """SegQMLevel (7.12.2 / 5.9.12): 15 (flat) for a lossless segment or without qmatrix, else qm_y / qm_u / qm_v."""
    for seg in range(MAX_SEGMENTS):
        for plane in range(3):
            var lvl = 15
            if ts.frame.using_qmatrix and not ts.lossless_arr[seg]:
                lvl = ts.frame.qm_y if plane == 0 else (ts.frame.qm_u if plane == 1 else ts.frame.qm_v)
            r.seg_qm_level[plane * MAX_SEGMENTS + seg] = lvl


def build_lf_input(ts: TileState) -> LfInput:
    var f = LfInput(ts.mi_rows, ts.mi_cols, ts.frame.width, ts.frame.height, ts.num_planes)
    f.loop_filter_level[0] = ts.frame.loop_filter_level0
    f.loop_filter_level[1] = ts.frame.loop_filter_level1
    f.loop_filter_level[2] = ts.frame.loop_filter_level2
    f.loop_filter_level[3] = ts.frame.loop_filter_level3
    f.loop_filter_sharpness = ts.frame.loop_filter_sharpness
    f.loop_filter_delta_enabled = ts.frame.loop_filter_delta_enabled
    f.loop_filter_ref_deltas = ts.frame.loop_filter_ref_deltas.copy()
    f.loop_filter_mode_deltas = ts.frame.loop_filter_mode_deltas.copy()
    f.delta_lf_multi = ts.frame.delta_lf_multi
    f.seg_feature_enabled = ts.frame.seg_feature_enabled.copy()
    f.seg_feature_data = ts.frame.seg_feature_data.copy()
    for r in range(ts.mi_rows):
        for c in range(ts.mi_cols):
            var i = r * ts.mi_cols + c
            var g = ts.at(r, c)
            f.mi_sizes[i] = UInt8(ts.mi_sizes[g])
            f.skips[i] = UInt8(ts.skips[g])
            f.ref_frames[i] = Int8(ts.ref_frames[g * 2])
            f.y_modes[i] = UInt8(ts.y_modes[g])
            f.segment_ids[i] = UInt8(ts.segment_ids[g])
            for k in range(4):
                f.delta_lfs[i * 4 + k] = Int8(ts.delta_lfs[g * 4 + k])
    var plane_stride = ts.stride * (ts.mi_rows + PAD)
    for p in range(ts.num_planes):
        var sx = ts.sub_x if p > 0 else 0
        var sy = ts.sub_y if p > 0 else 0
        for rp in range((ts.mi_rows + sy) >> sy):
            for cp in range((ts.mi_cols + sx) >> sx):
                f.lf_tx_sizes[p][rp * ts.mi_cols + cp] = UInt8(ts.lf_tx_sizes[p * plane_stride + ts.at(rp, cp)])
    return f^


def build_cdef_input(ts: TileState) -> CdefInput:
    var d = CdefInput(ts.mi_rows, ts.mi_cols)
    d.cdef_damping = ts.frame.cdef_damping
    d.cdef_y_pri_strength = ts.frame.cdef_y_pri_strength.copy()
    d.cdef_y_sec_strength = ts.frame.cdef_y_sec_strength.copy()
    d.cdef_uv_pri_strength = ts.frame.cdef_uv_pri_strength.copy()
    d.cdef_uv_sec_strength = ts.frame.cdef_uv_sec_strength.copy()
    for r16 in range((ts.mi_rows + 15) >> 4):
        for c16 in range(d.cdef_stride):
            d.cdef_idx[r16 * d.cdef_stride + c16] = Int8(ts.cdef_idx[ts.at(r16 * 16, c16 * 16)])
    for r in range(ts.mi_rows):
        for c in range(ts.mi_cols):
            d.skips[r * ts.mi_cols + c] = UInt8(ts.skips[ts.at(r, c)])
    return d^


def build_lr_input(ts: TileState) -> LrInput:
    var l = LrInput(ts.frame.height, ts.frame.upscaled_width, ts.sub_x, ts.sub_y, ts.num_planes, ts.frame.uses_lr,
                    ts.frame.frame_restoration_type, ts.frame.loop_restoration_size)
    for p in range(ts.num_planes):
        if ts.frame.frame_restoration_type[p] == RESTORE_NONE:
            continue
        var n = l.unit_rows[p] * l.unit_cols[p]
        for u in range(n):
            var s = ts.lr_base[p] + u
            l.lr_type[p][u] = UInt8(ts.lr_type[s])
            l.lr_sgr_set[p][u] = UInt8(ts.lr_sgr_set[s])
            for k in range(6):
                l.lr_wiener[p][u * 6 + k] = ts.lr_wiener[s * 6 + k]
            for k in range(2):
                l.lr_sgr_xqd[p][u * 2 + k] = ts.lr_sgr_xqd[s * 2 + k]
    return l^


def crop(f: Frame, w: Int, h: Int) -> Frame:
    """The visible w x h luma area (chroma (w + sub) >> sub) of a padded frame."""
    var o = Frame(w, h, f.bit_depth, f.sub_x, f.sub_y, len(f.planes))
    for p in range(len(f.planes)):
        for y in range(o.planes[p].h):
            for x in range(o.planes[p].w):
                o.planes[p].px[y * o.planes[p].stride + x] = f.planes[p].px[y * f.planes[p].stride + x]
    return o^


def decode_frame(st: Av1Stream) raises -> Frame:
    if st.frame.upscaled_width != st.frame.width:
        raise Error("av1dec: superres is not supported")
    var ts = parse_frame(st)
    var tables = Tables()
    # padded to whole 128x128 superblocks: transform blocks and CFL luma reads overhang MiCols * 4
    var frame = Frame(((ts.mi_cols * 4 + 127) >> 7) << 7, ((ts.mi_rows * 4 + 127) >> 7) << 7, st.seq.bit_depth, ts.sub_x, ts.sub_y, ts.num_planes)
    var rin = recon_input(st)
    seg_qm_levels(ts, rin)
    var iin = IntraInput()
    iin.mi_cols = ts.mi_cols
    iin.mi_rows = ts.mi_rows
    iin.enable_intra_edge_filter = st.seq.enable_intra_edge_filter
    for bi in range(len(ts.blocks)):
        replay_block(ts, tables, frame, rin, iin, bi)
    if ts.frame.loop_filter_level0 != 0 or ts.frame.loop_filter_level1 != 0:
        loop_filter(frame, build_lf_input(ts))
    var pre = frame.copy()
    if st.seq.enable_cdef and not ts.coded_lossless and not ts.frame.allow_intrabc:
        cdef(frame, pre, build_cdef_input(ts))
    if ts.frame.uses_lr:
        var cdef_out = frame.copy()
        loop_restoration(frame, cdef_out, pre, build_lr_input(ts))
    var out = crop(frame, st.frame.upscaled_width, st.frame.height)
    if st.frame.film_grain_pos >= 0:
        var b = Bits(st.data, st.frame.film_grain_pos >> 3, len(st.data))
        _ = b.f(st.frame.film_grain_pos & 7)
        var params = parse_film_grain_params(b, st.seq.mono_chrome, st.seq.subsampling_x, st.seq.subsampling_y)
        out = apply_film_grain(out, params, tables, st.seq.matrix_coefficients)
    return out^
