"""AV1 intra tile syntax (stage 4a): spec 5.11.2 onward, no residual."""
from std.collections import List
from imkit.av1obu import Av1Stream
from imkit.av1sym import SymbolDecoder
from imkit.av1tab import Cdfs, Scans
from imkit.av1state import (
    TileState, TileStats, BlockInfo,
    BLOCK_4X4, BLOCK_4X8, BLOCK_8X4, BLOCK_8X8, BLOCK_8X16, BLOCK_16X8,
    BLOCK_16X16, BLOCK_16X32, BLOCK_32X16, BLOCK_32X32, BLOCK_32X64,
    BLOCK_64X32, BLOCK_64X64, BLOCK_64X128, BLOCK_128X64, BLOCK_128X128,
    BLOCK_4X16, BLOCK_16X4, BLOCK_8X32, BLOCK_32X8, BLOCK_16X64, BLOCK_64X16,
    BLOCK_INVALID, BLOCK_SIZES,
    PARTITION_NONE, PARTITION_HORZ, PARTITION_VERT, PARTITION_SPLIT,
    PARTITION_HORZ_A, PARTITION_HORZ_B, PARTITION_VERT_A, PARTITION_VERT_B,
    PARTITION_HORZ_4, PARTITION_VERT_4,
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_64X64,
    DC_PRED, V_PRED, H_PRED, D45_PRED, D135_PRED, D113_PRED, D157_PRED,
    D203_PRED, D67_PRED, SMOOTH_PRED, SMOOTH_V_PRED, SMOOTH_H_PRED,
    PAETH_PRED, UV_CFL_PRED, INTRA_MODES,
    INTRA_FRAME, NONE_FRAME,
    SEG_LVL_ALT_Q, SEG_LVL_SKIP, SEG_LVL_MAX,
    RESTORE_NONE, RESTORE_WIENER, RESTORE_SGRPROJ, RESTORE_SWITCHABLE,
    TX_MODE_ONLY_4X4, TX_MODE_LARGEST, TX_MODE_SELECT,
    MAX_VARTX_DEPTH, MAX_TX_DEPTH, MI_SIZE, MI_SIZE_LOG2, MAX_SEGMENTS,
    FRAME_LF_COUNT, MAX_LOOP_FILTER, DELTA_Q_SMALL, DELTA_LF_SMALL,
    PALETTE_COLORS, PALETTE_NUM_NEIGHBORS, PALETTE_COLOR_CONTEXTS,
    PALETTE_MAX_COLOR_CONTEXT_HASH, CFL_ALPHABET_SIZE, CFL_JOINT_SIGNS,
    CFL_SIGN_ZERO, CFL_SIGN_NEG, CFL_SIGN_POS,
    MV_JOINT_HZVNZ, MV_JOINT_HNZVZ, MV_JOINT_HZVNZ_HNZVZ,
    MV_CLASS_0, CLASS0_SIZE, MV_INTRABC_CONTEXT, INTRABC_DELAY_PIXELS,
    SUPERRES_NUM, SGRPROJ_PARAMS_BITS, SGRPROJ_PRJ_SUBEXP_K, SGRPROJ_PRJ_BITS,
    SGRPROJ_XQD_MID0, SGRPROJ_XQD_MID1,
    BLOCK_WIDTH, BLOCK_HEIGHT, MI_WIDTH_LOG2, MI_HEIGHT_LOG2,
    NUM_4X4_WIDE, NUM_4X4_HIGH, SIZE_GROUP, MAX_TX_SIZE_RECT,
    MAX_TX_DEPTH_TABLE, SPLIT_TX_SIZE, TX_WIDTH, TX_HEIGHT,
    TX_WIDTH_LOG2, TX_HEIGHT_LOG2, TX_SIZE_SQR, TX_SIZE_SQR_UP,
    ADJUSTED_TX_SIZE, INTRA_MODE_CONTEXT, PALETTE_COLOR_HASH_MULTIPLIERS,
    PALETTE_COLOR_CONTEXT, SGR_PARAMS, WIENER_TAPS_MIN, WIENER_TAPS_MAX,
    WIENER_TAPS_K, SGRPROJ_XQD_MIN, SGRPROJ_XQD_MAX,
    block_width, block_height, num_4x4_wide, num_4x4_high,
    tx_width, tx_height, tx_width_log2, tx_height_log2,
    partition_subsize, subsampled_size, is_directional_mode,
    zeros, fill_ints, zero_bytes, cdf_row, cdf_store,
)
from imkit.av1coef import residual
from imkit.av1tab import (
    INTRA_FRAME_Y_MODE_N, Y_MODE_N, UV_MODE_CFL_NOT_ALLOWED_N,
    UV_MODE_CFL_ALLOWED_N, ANGLE_DELTA_N, INTRABC_N,
    PARTITION_W8_N, PARTITION_W16_N, PARTITION_W32_N, PARTITION_W64_N,
    PARTITION_W128_N, TX_8X8_N, TX_16X16_N, TX_32X32_N, TX_64X64_N,
    TXFM_SPLIT_N, FILTER_INTRA_MODE_N, FILTER_INTRA_N,
    SEGMENT_ID_N, SEGMENT_ID_PREDICTED_N,
    MV_JOINT_N, MV_SIGN_N, MV_CLASS_N, MV_CLASS0_BIT_N, MV_CLASS0_FR_N,
    MV_CLASS0_HP_N, MV_FR_N, MV_HP_N, MV_BIT_N,
    PALETTE_Y_SIZE_N, PALETTE_UV_SIZE_N,
    PALETTE_SIZE_2_Y_COLOR_N, PALETTE_SIZE_3_Y_COLOR_N,
    PALETTE_SIZE_4_Y_COLOR_N, PALETTE_SIZE_5_Y_COLOR_N,
    PALETTE_SIZE_6_Y_COLOR_N, PALETTE_SIZE_7_Y_COLOR_N,
    PALETTE_SIZE_8_Y_COLOR_N, PALETTE_SIZE_2_UV_COLOR_N,
    PALETTE_SIZE_3_UV_COLOR_N, PALETTE_SIZE_4_UV_COLOR_N,
    PALETTE_SIZE_5_UV_COLOR_N, PALETTE_SIZE_6_UV_COLOR_N,
    PALETTE_SIZE_7_UV_COLOR_N, PALETTE_SIZE_8_UV_COLOR_N,
    PALETTE_Y_MODE_N, PALETTE_UV_MODE_N,
    DELTA_Q_N, DELTA_LF_N,
    USE_WIENER_N, USE_SGRPROJ_N, RESTORATION_TYPE_N,
    CFL_SIGN_N, CFL_ALPHA_N,
)


def parse_tiles(st: Av1Stream) raises -> List[TileStats]:
    var out = List[TileStats]()
    var n = len(st.tile_offs)
    if n != len(st.tile_sizes):
        raise Error("av1tile: tile offset/size count mismatch")
    for i in range(n):
        var ts = TileState(st, i)
        ts.decode_tile()
        ts.sym.exit_process()
        if ts.stats.mi_covered != ts.stats.mi_total:
            raise Error("av1tile: tile " + String(i) + " covered " + String(ts.stats.mi_covered) + " of " + String(ts.stats.mi_total))
        out.append(ts.stats.copy())
    return out^


def read_partition(mut ts: TileState, bsl: Int, ctx: Int) raises -> Int:
    var off = ctx * (PARTITION_W8_N + 1)
    if bsl == 1:
        var c = cdf_row(ts.cdfs.partition_w8, off, PARTITION_W8_N)
        var s = ts.sym.read_symbol(c, PARTITION_W8_N)
        cdf_store(ts.cdfs.partition_w8, off, c, PARTITION_W8_N)
        return s
    if bsl == 2:
        var c = cdf_row(ts.cdfs.partition_w16, off, PARTITION_W16_N)
        var s = ts.sym.read_symbol(c, PARTITION_W16_N)
        cdf_store(ts.cdfs.partition_w16, off, c, PARTITION_W16_N)
        return s
    if bsl == 3:
        var c = cdf_row(ts.cdfs.partition_w32, off, PARTITION_W32_N)
        var s = ts.sym.read_symbol(c, PARTITION_W32_N)
        cdf_store(ts.cdfs.partition_w32, off, c, PARTITION_W32_N)
        return s
    if bsl == 4:
        var c = cdf_row(ts.cdfs.partition_w64, off, PARTITION_W64_N)
        var s = ts.sym.read_symbol(c, PARTITION_W64_N)
        cdf_store(ts.cdfs.partition_w64, off, c, PARTITION_W64_N)
        return s
    var c = cdf_row(ts.cdfs.partition_w128, off, PARTITION_W128_N)
    var s = ts.sym.read_symbol(c, PARTITION_W128_N)
    cdf_store(ts.cdfs.partition_w128, off, c, PARTITION_W128_N)
    return s


def read_split_or_horz(mut ts: TileState, bsl: Int, ctx: Int) raises -> Bool:
    var off = ctx * (PARTITION_W8_N + 1)
    var part_cdf: List[UInt16]
    var pn = PARTITION_W8_N
    if bsl == 2:
        off = ctx * (PARTITION_W16_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w16, off, PARTITION_W16_N)
        pn = PARTITION_W16_N
    elif bsl == 3:
        off = ctx * (PARTITION_W32_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w32, off, PARTITION_W32_N)
        pn = PARTITION_W32_N
    elif bsl == 4:
        off = ctx * (PARTITION_W64_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w64, off, PARTITION_W64_N)
        pn = PARTITION_W64_N
    else:
        off = ctx * (PARTITION_W128_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w128, off, PARTITION_W128_N)
        pn = PARTITION_W128_N
    var psum = 0
    psum += Int(part_cdf[PARTITION_VERT]) - Int(part_cdf[PARTITION_VERT - 1])
    psum += Int(part_cdf[PARTITION_SPLIT]) - Int(part_cdf[PARTITION_SPLIT - 1])
    psum += Int(part_cdf[PARTITION_HORZ_A]) - Int(part_cdf[PARTITION_HORZ_A - 1])
    psum += Int(part_cdf[PARTITION_VERT_A]) - Int(part_cdf[PARTITION_VERT_A - 1])
    psum += Int(part_cdf[PARTITION_VERT_B]) - Int(part_cdf[PARTITION_VERT_B - 1])
    if bsl != 5:
        psum += Int(part_cdf[PARTITION_VERT_4]) - Int(part_cdf[PARTITION_VERT_4 - 1])
    var c = List[UInt16]()
    c.append(UInt16((1 << 15) - psum))
    c.append(UInt16(1 << 15))
    c.append(UInt16(0))
    var s = ts.sym.read_symbol(c, 2)
    return s == 1


def read_split_or_vert(mut ts: TileState, bsl: Int, ctx: Int) raises -> Bool:
    var off = ctx * (PARTITION_W8_N + 1)
    var part_cdf: List[UInt16]
    if bsl == 2:
        off = ctx * (PARTITION_W16_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w16, off, PARTITION_W16_N)
    elif bsl == 3:
        off = ctx * (PARTITION_W32_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w32, off, PARTITION_W32_N)
    elif bsl == 4:
        off = ctx * (PARTITION_W64_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w64, off, PARTITION_W64_N)
    else:
        off = ctx * (PARTITION_W128_N + 1)
        part_cdf = cdf_row(ts.cdfs.partition_w128, off, PARTITION_W128_N)
    var psum = 0
    psum += Int(part_cdf[PARTITION_HORZ]) - Int(part_cdf[PARTITION_HORZ - 1])
    psum += Int(part_cdf[PARTITION_SPLIT]) - Int(part_cdf[PARTITION_SPLIT - 1])
    psum += Int(part_cdf[PARTITION_HORZ_A]) - Int(part_cdf[PARTITION_HORZ_A - 1])
    psum += Int(part_cdf[PARTITION_HORZ_B]) - Int(part_cdf[PARTITION_HORZ_B - 1])
    psum += Int(part_cdf[PARTITION_VERT_A]) - Int(part_cdf[PARTITION_VERT_A - 1])
    if bsl != 5:
        psum += Int(part_cdf[PARTITION_HORZ_4]) - Int(part_cdf[PARTITION_HORZ_4 - 1])
    var c = List[UInt16]()
    c.append(UInt16((1 << 15) - psum))
    c.append(UInt16(1 << 15))
    c.append(UInt16(0))
    var s = ts.sym.read_symbol(c, 2)
    return s == 1


def decode_partition(mut ts: TileState, r: Int, c: Int, bsize: Int) raises:
    if r >= ts.mi_rows or c >= ts.mi_cols:
        return
    var avail_u = ts.in_tile(r - 1, c)
    var avail_l = ts.in_tile(r, c - 1)
    var num4 = num_4x4_wide(bsize)
    var half = num4 >> 1
    var quarter = half >> 1
    var has_rows = (r + half) < ts.mi_rows
    var has_cols = (c + half) < ts.mi_cols
    var partition = PARTITION_NONE
    if bsize < BLOCK_8X8:
        partition = PARTITION_NONE
    elif has_rows and has_cols:
        var bsl = MI_WIDTH_LOG2[bsize]
        var above = avail_u and MI_WIDTH_LOG2[ts.mi_sizes[ts.at(r - 1, c)]] < bsl
        var left = avail_l and MI_HEIGHT_LOG2[ts.mi_sizes[ts.at(r, c - 1)]] < bsl
        var ctx = (1 if left else 0) * 2 + (1 if above else 0)
        partition = read_partition(ts, bsl, ctx)
    elif has_cols:
        var bsl = MI_WIDTH_LOG2[bsize]
        var above = avail_u and MI_WIDTH_LOG2[ts.mi_sizes[ts.at(r - 1, c)]] < bsl
        var left = avail_l and MI_HEIGHT_LOG2[ts.mi_sizes[ts.at(r, c - 1)]] < bsl
        var ctx = (1 if left else 0) * 2 + (1 if above else 0)
        var split = read_split_or_horz(ts, bsl, ctx)
        if split:
            partition = PARTITION_SPLIT
        else:
            partition = PARTITION_HORZ
    elif has_rows:
        var bsl = MI_WIDTH_LOG2[bsize]
        var above = avail_u and MI_WIDTH_LOG2[ts.mi_sizes[ts.at(r - 1, c)]] < bsl
        var left = avail_l and MI_HEIGHT_LOG2[ts.mi_sizes[ts.at(r, c - 1)]] < bsl
        var ctx = (1 if left else 0) * 2 + (1 if above else 0)
        var split = read_split_or_vert(ts, bsl, ctx)
        if split:
            partition = PARTITION_SPLIT
        else:
            partition = PARTITION_VERT
    else:
        partition = PARTITION_SPLIT
    var sub_size = partition_subsize(partition, bsize)
    var split_size = partition_subsize(PARTITION_SPLIT, bsize)
    if sub_size == BLOCK_INVALID and partition != PARTITION_SPLIT:
        raise Error("av1tile: invalid partition sub size")
    if partition == PARTITION_NONE:
        decode_block(ts, r, c, sub_size)
    elif partition == PARTITION_HORZ:
        decode_block(ts, r, c, sub_size)
        if has_rows:
            decode_block(ts, r + half, c, sub_size)
    elif partition == PARTITION_VERT:
        decode_block(ts, r, c, sub_size)
        if has_cols:
            decode_block(ts, r, c + half, sub_size)
    elif partition == PARTITION_SPLIT:
        decode_partition(ts, r, c, sub_size)
        decode_partition(ts, r, c + half, sub_size)
        decode_partition(ts, r + half, c, sub_size)
        decode_partition(ts, r + half, c + half, sub_size)
    elif partition == PARTITION_HORZ_A:
        decode_block(ts, r, c, split_size)
        decode_block(ts, r, c + half, split_size)
        decode_block(ts, r + half, c, sub_size)
    elif partition == PARTITION_HORZ_B:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r + half, c, split_size)
        decode_block(ts, r + half, c + half, split_size)
    elif partition == PARTITION_VERT_A:
        decode_block(ts, r, c, split_size)
        decode_block(ts, r + half, c, split_size)
        decode_block(ts, r, c + half, sub_size)
    elif partition == PARTITION_VERT_B:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r, c + half, split_size)
        decode_block(ts, r + half, c + half, split_size)
    elif partition == PARTITION_HORZ_4:
        decode_block(ts, r + quarter * 0, c, sub_size)
        decode_block(ts, r + quarter * 1, c, sub_size)
        decode_block(ts, r + quarter * 2, c, sub_size)
        if r + quarter * 3 < ts.mi_rows:
            decode_block(ts, r + quarter * 3, c, sub_size)
    elif partition == PARTITION_VERT_4:
        decode_block(ts, r, c + quarter * 0, sub_size)
        decode_block(ts, r, c + quarter * 1, sub_size)
        decode_block(ts, r, c + quarter * 2, sub_size)
        if c + quarter * 3 < ts.mi_cols:
            decode_block(ts, r, c + quarter * 3, sub_size)


def decode_block(mut ts: TileState, r: Int, c: Int, bsize: Int) raises:
    ts.mi_row = r
    ts.mi_col = c
    ts.mi_size = bsize
    var bw4 = num_4x4_wide(bsize)
    var bh4 = num_4x4_high(bsize)
    ts.has_chroma = False
    if bh4 == 1 and ts.seq.subsampling_y and (r & 1) == 0:
        ts.has_chroma = False
    elif bw4 == 1 and ts.seq.subsampling_x and (c & 1) == 0:
        ts.has_chroma = False
    else:
        ts.has_chroma = ts.seq.num_planes > 1
    ts.avail_u = ts.in_tile(r - 1, c)
    ts.avail_l = ts.in_tile(r, c - 1)
    ts.avail_u_chroma = ts.avail_u
    ts.avail_l_chroma = ts.avail_l
    if ts.has_chroma:
        if ts.seq.subsampling_y and bh4 == 1:
            ts.avail_u_chroma = ts.in_tile(r - 2, c)
        if ts.seq.subsampling_x and bw4 == 1:
            ts.avail_l_chroma = ts.in_tile(r, c - 2)
    else:
        ts.avail_u_chroma = False
        ts.avail_l_chroma = False
    intra_frame_mode_info(ts)
    palette_tokens(ts)
    read_block_tx_size(ts)
    if ts.skip:
        reset_block_context(ts, bw4, bh4)
    for y in range(bh4):
        for x in range(bw4):
            var idx = ts.at(r + y, c + x)
            ts.y_modes[idx] = ts.y_mode
            if ts.ref_frames[ts.at(r + y, c + x) * 2] == INTRA_FRAME and ts.has_chroma:
                ts.uv_modes[idx] = ts.uv_mode
            ts.ref_frames[ts.at(r + y, c + x) * 2] = INTRA_FRAME
            ts.ref_frames[ts.at(r + y, c + x) * 2 + 1] = NONE_FRAME
            if ts.use_intrabc:
                ts.comp_group_idxs[idx] = 0
                ts.compound_idxs[idx] = 0
            ts.is_inters[idx] = 1 if ts.is_inter else 0
            ts.skip_modes[idx] = 1 if ts.skip_mode else 0
            ts.skips[idx] = 1 if ts.skip else 0
            ts.tx_sizes[idx] = ts.tx_size
            ts.mi_sizes[idx] = ts.mi_size
            ts.segment_ids[idx] = ts.segment_id
            ts.palette_sizes[idx] = ts.palette_size_y
            ts.palette_sizes[ts.mi_rows * ts.mi_stride + idx] = ts.palette_size_uv
            for i in range(ts.palette_size_y):
                ts.palette_colors[(idx * 2) * PALETTE_COLORS + i] = ts.palette_colors_y[i]
            for i in range(ts.palette_size_uv):
                ts.palette_colors[(idx * 2 + 1) * PALETTE_COLORS + i] = ts.palette_colors_u[i]
            for i in range(FRAME_LF_COUNT):
                ts.delta_lf[i] = ts.delta_lf[i]
    residual(ts)
    var info = BlockInfo()
    info.mi_row = r
    info.mi_col = c
    info.mi_size = bsize
    info.segment_id = ts.segment_id
    info.skip = ts.skip
    info.qindex = ts.current_qindex
    info.use_intrabc = ts.use_intrabc
    info.mv_row = ts.mv_row
    info.mv_col = ts.mv_col
    info.y_mode = ts.y_mode
    info.uv_mode = ts.uv_mode
    info.angle_delta_y = ts.angle_delta_y
    info.angle_delta_uv = ts.angle_delta_uv
    info.cfl_alpha_u = ts.cfl_alpha_u
    info.cfl_alpha_v = ts.cfl_alpha_v
    info.use_filter_intra = ts.use_filter_intra
    info.filter_intra_mode = ts.filter_intra_mode
    info.palette_size_y = ts.palette_size_y
    info.palette_size_uv = ts.palette_size_uv
    info.palette_colors_y = ts.palette_colors_y.copy()
    info.palette_colors_u = ts.palette_colors_u.copy()
    info.palette_colors_v = ts.palette_colors_v.copy()
    info.color_map_offset = len(ts.color_maps)
    info.tx_size = ts.tx_size
    ts.blocks.append(info)
    ts.stats.blocks += 1
    ts.stats.mi_covered += bw4 * bh4
    if ts.skip:
        ts.stats.skip += 1
    if ts.use_intrabc:
        ts.stats.intrabc += 1
    if ts.palette_size_y > 0 or ts.palette_size_uv > 0:
        ts.stats.palette += 1
    if ts.uv_mode == UV_CFL_PRED:
        ts.stats.cfl += 1
    if ts.use_filter_intra:
        ts.stats.filter_intra += 1


def reset_block_context(mut ts: TileState, bw4: Int, bh4: Int):
    for plane in range(1 + 2 * (1 if ts.has_chroma else 0)):
        var sub_x = 0
        var sub_y = 0
        if plane > 0:
            if ts.seq.subsampling_x:
                sub_x = 1
            if ts.seq.subsampling_y:
                sub_y = 1
        var c0 = ts.mi_col >> sub_x
        var c1 = (ts.mi_col + bw4) >> sub_x
        for i in range(c0, c1):
            if i >= 0 and i < len(ts.above_level):
                ts.above_level[plane * (ts.mi_cols + 2) + i] = 0
                ts.above_dc[plane * (ts.mi_cols + 2) + i] = 0
        var r0 = ts.mi_row >> sub_y
        var r1 = (ts.mi_row + bh4) >> sub_y
        for i in range(r0, r1):
            if i >= 0 and i < len(ts.left_level):
                ts.left_level[plane * (ts.mi_rows + 2) + i] = 0
                ts.left_dc[plane * (ts.mi_rows + 2) + i] = 0


def intra_frame_mode_info(mut ts: TileState) raises:
    ts.skip = False
    if ts.seg_id_pre_skip:
        intra_segment_id(ts)
    ts.skip_mode = False
    read_skip(ts)
    if not ts.seg_id_pre_skip:
        intra_segment_id(ts)
    read_cdef(ts)
    read_delta_qindex(ts)
    read_delta_lf(ts)
    ts.read_deltas = False
    if ts.frame.allow_intrabc:
        var c = cdf_row(ts.cdfs.intrabc, 0, INTRABC_N)
        var s = ts.sym.read_symbol(c, INTRABC_N)
        cdf_store(ts.cdfs.intrabc, 0, c, INTRABC_N)
        ts.use_intrabc = s == 1
    else:
        ts.use_intrabc = False
    if ts.use_intrabc:
        ts.is_inter = True
        ts.y_mode = DC_PRED
        ts.uv_mode = DC_PRED
        ts.palette_size_y = 0
        ts.palette_size_uv = 0
        ts.mv_row = 0
        ts.mv_col = 0
        read_mv(ts, MV_INTRABC_CONTEXT)
    else:
        ts.is_inter = False
        ts.uv_mode = DC_PRED
        ts.cfl_alpha_u = 0
        ts.cfl_alpha_v = 0
        ts.palette_size_y = 0
        ts.palette_size_uv = 0
        ts.use_filter_intra = False
        ts.filter_intra_mode = 0
        var above_mode = DC_PRED
        var left_mode = DC_PRED
        if ts.avail_u:
            above_mode = ts.y_modes[ts.at(ts.mi_row - 1, ts.mi_col)]
        if ts.avail_l:
            left_mode = ts.y_modes[ts.at(ts.mi_row, ts.mi_col - 1)]
        var actx = INTRA_MODE_CONTEXT[above_mode]
        var lctx = INTRA_MODE_CONTEXT[left_mode]
        var off = (actx * INTRA_MODES + lctx) * (INTRA_FRAME_Y_MODE_N + 1)
        var c = cdf_row(ts.cdfs.intra_frame_y_mode, off, INTRA_FRAME_Y_MODE_N)
        var s = ts.sym.read_symbol(c, INTRA_FRAME_Y_MODE_N)
        cdf_store(ts.cdfs.intra_frame_y_mode, off, c, INTRA_FRAME_Y_MODE_N)
        ts.y_mode = s
        intra_angle_info_y(ts)
        if ts.has_chroma:
            var lossless = ts.lossless
            var plane_bsize = subsampled_size(ts.mi_size, True, True)
            var cfl_allowed = False
            if lossless and plane_bsize == BLOCK_4X4:
                cfl_allowed = True
            elif not lossless and max_int(block_width(ts.mi_size), block_height(ts.mi_size)) <= 32:
                cfl_allowed = True
            var n = UV_MODE_CFL_ALLOWED_N if cfl_allowed else UV_MODE_CFL_NOT_ALLOWED_N
            var uv_off = ts.y_mode * (n + 1)
            var uv_cdf = cdf_row(ts.cdfs.uv_mode_cfl_allowed if cfl_allowed else ts.cdfs.uv_mode_cfl_not_allowed, uv_off, n)
            var uv_s = ts.sym.read_symbol(uv_cdf, n)
            if cfl_allowed:
                cdf_store(ts.cdfs.uv_mode_cfl_allowed, uv_off, uv_cdf, n)
            else:
                cdf_store(ts.cdfs.uv_mode_cfl_not_allowed, uv_off, uv_cdf, n)
            ts.uv_mode = uv_s
            if ts.uv_mode == UV_CFL_PRED:
                read_cfl_alphas(ts)
            intra_angle_info_uv(ts)
        if ts.mi_size >= BLOCK_8X8 and block_width(ts.mi_size) <= 64 and block_height(ts.mi_size) <= 64 and ts.frame.allow_screen_content_tools:
            palette_mode_info(ts)
        filter_intra_mode_info(ts)


def intra_segment_id(mut ts: TileState) raises:
    if ts.frame.segmentation_enabled:
        read_segment_id(ts)
    else:
        ts.segment_id = 0
    ts.lossless = ts.get_qindex(ts.segment_id) == 0


def read_segment_id(mut ts: TileState) raises:
    var prev_ul = -1
    var prev_u = -1
    var prev_l = -1
    if ts.avail_u and ts.avail_l:
        prev_ul = ts.segment_ids[ts.at(ts.mi_row - 1, ts.mi_col - 1)]
    if ts.avail_u:
        prev_u = ts.segment_ids[ts.at(ts.mi_row - 1, ts.mi_col)]
    if ts.avail_l:
        prev_l = ts.segment_ids[ts.at(ts.mi_row, ts.mi_col - 1)]
    var pred = 0
    if prev_u == -1:
        if prev_l == -1:
            pred = 0
        else:
            pred = prev_l
    elif prev_l == -1:
        pred = prev_u
    else:
        if prev_ul == prev_u:
            pred = prev_u
        else:
            pred = prev_l
    if ts.skip:
        ts.segment_id = pred
    else:
        var ctx = 0
        if prev_ul < 0:
            ctx = 0
        elif prev_ul == prev_u and prev_ul == prev_l:
            ctx = 2
        elif prev_ul == prev_u or prev_ul == prev_l or prev_u == prev_l:
            ctx = 1
        else:
            ctx = 0
        var off = ctx * (SEGMENT_ID_N + 1)
        var c = cdf_row(ts.cdfs.segment_id, off, SEGMENT_ID_N)
        var s = ts.sym.read_symbol(c, SEGMENT_ID_N)
        cdf_store(ts.cdfs.segment_id, off, c, SEGMENT_ID_N)
        ts.segment_id = neg_deinterleave(s, pred, ts.last_active_seg_id + 1)


def neg_deinterleave(diff: Int, ref: Int, maximum: Int) -> Int:
    if ref == 0:
        return diff
    if ref >= maximum - 1:
        return maximum - diff - 1
    if 2 * ref < maximum:
        if diff <= 2 * ref:
            if diff & 1:
                return ref + ((diff + 1) >> 1)
            else:
                return ref - (diff >> 1)
        return diff
    else:
        if diff <= 2 * (maximum - ref - 1):
            if diff & 1:
                return ref + ((diff + 1) >> 1)
            else:
                return ref - (diff >> 1)
        return maximum - (diff + 1)


def read_skip(mut ts: TileState) raises:
    if ts.seg_id_pre_skip and ts.seg_feature_active(SEG_LVL_SKIP):
        ts.skip = True
        return
    var ctx = 0
    if ts.avail_u:
        ctx += ts.skips[ts.at(ts.mi_row - 1, ts.mi_col)]
    if ts.avail_l:
        ctx += ts.skips[ts.at(ts.mi_row, ts.mi_col - 1)]
    var off = ctx * (3 + 1)
    var c = cdf_row(ts.cdfs.skip, off, 2)
    var s = ts.sym.read_symbol(c, 2)
    cdf_store(ts.cdfs.skip, off, c, 2)
    ts.skip = s == 1


def read_cdef(mut ts: TileState) raises:
    if ts.skip or ts.coded_lossless or not ts.frame.enable_cdef or ts.frame.allow_intrabc:
        return
    var s4 = num_4x4_wide(BLOCK_64X64)
    var mask = ~(s4 - 1)
    var r = ts.mi_row & mask
    var c = ts.mi_col & mask
    if r < 0 or c < 0 or r >= ts.mi_rows or c >= ts.mi_cols:
        return
    if ts.cdef_idx[ts.at(r, c)] == -1:
        if ts.frame.cdef_bits < 0 or ts.frame.cdef_bits > 8:
            raise Error("av1tile: bad cdef_bits")
        var v = ts.sym.read_literal(ts.frame.cdef_bits)
        ts.cdef_idx[ts.at(r, c)] = v
        var w4 = num_4x4_wide(ts.mi_size)
        var h4 = num_4x4_high(ts.mi_size)
        for i in range(r, r + h4, s4):
            for j in range(c, c + w4, s4):
                if i < ts.mi_rows and j < ts.mi_cols:
                    ts.cdef_idx[ts.at(i, j)] = v


def read_delta_qindex(mut ts: TileState) raises:
    var sb = BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64
    if ts.mi_size == sb and ts.skip:
        return
    if not ts.read_deltas:
        return
    var off = 0
    var c = cdf_row(ts.cdfs.delta_q, 0, DELTA_Q_N)
    var s = ts.sym.read_symbol(c, DELTA_Q_N)
    cdf_store(ts.cdfs.delta_q, 0, c, DELTA_Q_N)
    var abs_v = s
    if abs_v == DELTA_Q_SMALL:
        var rem = ts.sym.read_literal(3) + 1
        if rem < 1 or rem > 24:
            raise Error("av1tile: bad delta q rem bits")
        var bits = ts.sym.read_literal(rem)
        abs_v = bits + (1 << rem) + 1
    if abs_v != 0:
        var sign = ts.sym.read_literal(1)
        var reduced = -abs_v if sign != 0 else abs_v
        ts.current_qindex += reduced << ts.frame.delta_q_res
        if ts.current_qindex < 1:
            ts.current_qindex = 1
        if ts.current_qindex > 255:
            ts.current_qindex = 255


def read_delta_lf(mut ts: TileState) raises:
    var sb = BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64
    if ts.mi_size == sb and ts.skip:
        return
    if not (ts.read_deltas and ts.frame.delta_lf_present):
        return
    var count = 1
    if ts.frame.delta_lf_multi:
        count = FRAME_LF_COUNT if ts.seq.num_planes > 1 else FRAME_LF_COUNT - 2
    for i in range(count):
        var off = i * (DELTA_LF_N + 1) if ts.frame.delta_lf_multi else 0
        if off + DELTA_LF_N + 1 > len(ts.cdfs.delta_lf):
            off = 0
        var c = cdf_row(ts.cdfs.delta_lf, off, DELTA_LF_N)
        var s = ts.sym.read_symbol(c, DELTA_LF_N)
        cdf_store(ts.cdfs.delta_lf, off, c, DELTA_LF_N)
        var abs_v = s
        if abs_v == DELTA_LF_SMALL:
            var rem = ts.sym.read_literal(3) + 1
            if rem < 1 or rem > 24:
                raise Error("av1tile: bad delta lf rem bits")
            var bits = ts.sym.read_literal(rem)
            abs_v = bits + (1 << rem) + 1
        if abs_v != 0:
            var sign = ts.sym.read_literal(1)
            var reduced = -abs_v if sign != 0 else abs_v
            var v = ts.delta_lf[i] + (reduced << ts.frame.delta_lf_res)
            if v < -MAX_LOOP_FILTER:
                v = -MAX_LOOP_FILTER
            if v > MAX_LOOP_FILTER:
                v = MAX_LOOP_FILTER
            ts.delta_lf[i] = v


def intra_angle_info_y(mut ts: TileState) raises:
    ts.angle_delta_y = 0
    if ts.mi_size >= BLOCK_8X8 and is_directional_mode(ts.y_mode):
        var off = (ts.y_mode - V_PRED) * (ANGLE_DELTA_N + 1)
        var c = cdf_row(ts.cdfs.angle_delta, off, ANGLE_DELTA_N)
        var s = ts.sym.read_symbol(c, ANGLE_DELTA_N)
        cdf_store(ts.cdfs.angle_delta, off, c, ANGLE_DELTA_N)
        ts.angle_delta_y = s - 3


def intra_angle_info_uv(mut ts: TileState) raises:
    ts.angle_delta_uv = 0
    if ts.mi_size >= BLOCK_8X8 and is_directional_mode(ts.uv_mode):
        var off = (ts.uv_mode - V_PRED) * (ANGLE_DELTA_N + 1)
        var c = cdf_row(ts.cdfs.angle_delta, off, ANGLE_DELTA_N)
        var s = ts.sym.read_symbol(c, ANGLE_DELTA_N)
        cdf_store(ts.cdfs.angle_delta, off, c, ANGLE_DELTA_N)
        ts.angle_delta_uv = s - 3


def read_cfl_alphas(mut ts: TileState) raises:
    var c = cdf_row(ts.cdfs.cfl_sign, 0, CFL_SIGN_N)
    var s = ts.sym.read_symbol(c, CFL_SIGN_N)
    cdf_store(ts.cdfs.cfl_sign, 0, c, CFL_SIGN_N)
    var sign_u = (s + 1) // 3
    var sign_v = (s + 1) % 3
    if sign_u != CFL_SIGN_ZERO:
        var ctx = (sign_u - 1) * 3 + sign_v
        var off = ctx * (CFL_ALPHA_N + 1)
        var ca = cdf_row(ts.cdfs.cfl_alpha, off, CFL_ALPHA_N)
        var au = ts.sym.read_symbol(ca, CFL_ALPHA_N)
        cdf_store(ts.cdfs.cfl_alpha, off, ca, CFL_ALPHA_N)
        ts.cfl_alpha_u = 1 + au
        if sign_u == CFL_SIGN_NEG:
            ts.cfl_alpha_u = -ts.cfl_alpha_u
    else:
        ts.cfl_alpha_u = 0
    if sign_v != CFL_SIGN_ZERO:
        var ctx = (sign_v - 1) * 3 + sign_u
        var off = ctx * (CFL_ALPHA_N + 1)
        var ca = cdf_row(ts.cdfs.cfl_alpha, off, CFL_ALPHA_N)
        var av = ts.sym.read_symbol(ca, CFL_ALPHA_N)
        cdf_store(ts.cdfs.cfl_alpha, off, ca, CFL_ALPHA_N)
        ts.cfl_alpha_v = 1 + av
        if sign_v == CFL_SIGN_NEG:
            ts.cfl_alpha_v = -ts.cfl_alpha_v
    else:
        ts.cfl_alpha_v = 0


def palette_mode_info(mut ts: TileState) raises:
    if ts.y_mode != DC_PRED:
        return
    var bsize_ctx = MI_WIDTH_LOG2[ts.mi_size] + MI_HEIGHT_LOG2[ts.mi_size] - 2
    if bsize_ctx < 0:
        bsize_ctx = 0
    var ctx = 0
    if ts.avail_u:
        var idx = ts.at(ts.mi_row - 1, ts.mi_col)
        if ts.palette_sizes[idx] > 0:
            ctx += 1
    if ts.avail_l:
        var idx = ts.at(ts.mi_row, ts.mi_col - 1)
        if ts.palette_sizes[idx] > 0:
            ctx += 1
    var off = (bsize_ctx * 3 + ctx) * (PALETTE_Y_MODE_N + 1)
    var c = cdf_row(ts.cdfs.palette_y_mode, off, PALETTE_Y_MODE_N)
    var s = ts.sym.read_symbol(c, PALETTE_Y_MODE_N)
    cdf_store(ts.cdfs.palette_y_mode, off, c, PALETTE_Y_MODE_N)
    if s == 0:
        return
    var size_off = bsize_ctx * (PALETTE_Y_SIZE_N + 1)
    var sc = cdf_row(ts.cdfs.palette_y_size, size_off, PALETTE_Y_SIZE_N)
    var ss = ts.sym.read_symbol(sc, PALETTE_Y_SIZE_N)
    cdf_store(ts.cdfs.palette_y_size, size_off, sc, PALETTE_Y_SIZE_N)
    ts.palette_size_y = ss + 2
    if ts.palette_size_y < 2 or ts.palette_size_y > 8:
        raise Error("av1tile: bad palette size y")
    var cache = List[Int]()
    var cache_n = get_palette_cache(ts, 0, cache)
    var idx = 0
    for i in range(cache_n):
        if idx >= ts.palette_size_y:
            break
        var use = ts.sym.read_literal(1)
        if use != 0:
            ts.palette_colors_y.append(UInt8(cache[i]))
            idx += 1
    if idx < ts.palette_size_y:
        ts.palette_colors_y.append(UInt8(ts.sym.read_literal(ts.seq.bit_depth)))
        idx += 1
    var palette_bits = 0
    if idx < ts.palette_size_y:
        var min_bits = ts.seq.bit_depth - 3
        var extra = ts.sym.read_literal(2)
        palette_bits = min_bits + extra
    while idx < ts.palette_size_y:
        if palette_bits < 0 or palette_bits > 8:
            raise Error("av1tile: bad palette bits")
        var delta = ts.sym.read_literal(palette_bits) + 1
        var prev = Int(ts.palette_colors_y[idx - 1])
        var v = prev + delta
        var maxv = (1 << ts.seq.bit_depth) - 1
        if v > maxv:
            v = maxv
        ts.palette_colors_y.append(UInt8(v))
        var rng = (1 << ts.seq.bit_depth) - v - 1
        var cb = ceil_log2(rng)
        if cb < palette_bits:
            palette_bits = cb
        idx += 1
    sort_u8(ts.palette_colors_y, 0, ts.palette_size_y - 1)
    if ts.has_chroma and ts.uv_mode == DC_PRED:
        var offu = (bsize_ctx * 3 + (1 if ts.palette_size_y > 0 else 0)) * (PALETTE_UV_MODE_N + 1)
        var cu = cdf_row(ts.cdfs.palette_uv_mode, offu, PALETTE_UV_MODE_N)
        var su = ts.sym.read_symbol(cu, PALETTE_UV_MODE_N)
        cdf_store(ts.cdfs.palette_uv_mode, offu, cu, PALETTE_UV_MODE_N)
        if su != 0:
            var us_off = bsize_ctx * (PALETTE_UV_SIZE_N + 1)
            var usc = cdf_row(ts.cdfs.palette_uv_size, us_off, PALETTE_UV_SIZE_N)
            var uss = ts.sym.read_symbol(usc, PALETTE_UV_SIZE_N)
            cdf_store(ts.cdfs.palette_uv_size, us_off, usc, PALETTE_UV_SIZE_N)
            ts.palette_size_uv = uss + 2
            if ts.palette_size_uv < 2 or ts.palette_size_uv > 8:
                raise Error("av1tile: bad palette size uv")
            var ucache = List[Int]()
            var ucn = get_palette_cache(ts, 1, ucache)
            var uidx = 0
            for i in range(ucn):
                if uidx >= ts.palette_size_uv:
                    break
                var use = ts.sym.read_literal(1)
                if use != 0:
                    ts.palette_colors_u.append(UInt8(ucache[i]))
                    uidx += 1
            if uidx < ts.palette_size_uv:
                ts.palette_colors_u.append(UInt8(ts.sym.read_literal(ts.seq.bit_depth)))
                uidx += 1
            var ubits = 0
            if uidx < ts.palette_size_uv:
                var min_bits = ts.seq.bit_depth - 3
                var extra = ts.sym.read_literal(2)
                ubits = min_bits + extra
            while uidx < ts.palette_size_uv:
                if ubits < 0 or ubits > 8:
                    raise Error("av1tile: bad palette bits u")
                var delta = ts.sym.read_literal(ubits) + 1
                var prev = Int(ts.palette_colors_u[uidx - 1])
                var v = prev + delta
                var maxv = (1 << ts.seq.bit_depth) - 1
                if v > maxv:
                    v = maxv
                ts.palette_colors_u.append(UInt8(v))
                var rng = (1 << ts.seq.bit_depth) - v
                var cb = ceil_log2(rng)
                if cb < ubits:
                    ubits = cb
                uidx += 1
            sort_u8(ts.palette_colors_u, 0, ts.palette_size_uv - 1)
            var delta_encode = ts.sym.read_literal(1)
            if delta_encode != 0:
                var min_bits = ts.seq.bit_depth - 4
                var extra = ts.sym.read_literal(2)
                var vbits = min_bits + extra
                ts.palette_colors_v.append(UInt8(ts.sym.read_literal(ts.seq.bit_depth)))
                var maxv = 1 << ts.seq.bit_depth
                for vi in range(1, ts.palette_size_uv):
                    if vbits < 0 or vbits > 8:
                        raise Error("av1tile: bad palette bits v")
                    var dv = ts.sym.read_literal(vbits)
                    if dv != 0:
                        var sign = ts.sym.read_literal(1)
                        if sign != 0:
                            dv = -dv
                    var val = Int(ts.palette_colors_v[vi - 1]) + dv
                    if val < 0:
                        val += maxv
                    if val >= maxv:
                        val -= maxv
                    if val < 0:
                        val = 0
                    if val > maxv - 1:
                        val = maxv - 1
                    ts.palette_colors_v.append(UInt8(val))
            else:
                for vi in range(ts.palette_size_uv):
                    ts.palette_colors_v.append(UInt8(ts.sym.read_literal(ts.seq.bit_depth)))


def get_palette_cache(ts: TileState, plane: Int, cache: List[Int]) -> Int:
    var above_n = 0
    if ((ts.mi_row * MI_SIZE) % 64) != 0:
        if ts.mi_row > 0:
            var idx = ts.at(ts.mi_row - 1, ts.mi_col)
            above_n = ts.palette_sizes[idx + plane * ts.mi_rows * ts.mi_stride]
    var left_n = 0
    if ts.avail_l:
        var idx = ts.at(ts.mi_row, ts.mi_col - 1)
        left_n = ts.palette_sizes[idx + plane * ts.mi_rows * ts.mi_stride]
    var above_idx = 0
    var left_idx = 0
    var n = 0
    while above_idx < above_n and left_idx < left_n:
        var ai = ts.at(ts.mi_row - 1, ts.mi_col)
        var li = ts.at(ts.mi_row, ts.mi_col - 1)
        var above_c = ts.palette_colors[(ai * 2 + plane) * PALETTE_COLORS + above_idx]
        var left_c = ts.palette_colors[(li * 2 + plane) * PALETTE_COLORS + left_idx]
        if left_c < above_c:
            if n == 0 or left_c != cache[n - 1]:
                cache.append(left_c)
                n += 1
            left_idx += 1
        else:
            if n == 0 or above_c != cache[n - 1]:
                cache.append(above_c)
                n += 1
            above_idx += 1
            if left_c == above_c:
                left_idx += 1
    while above_idx < above_n:
        var ai = ts.at(ts.mi_row - 1, ts.mi_col)
        var val = ts.palette_colors[(ai * 2 + plane) * PALETTE_COLORS + above_idx]
        above_idx += 1
        if n == 0 or val != cache[n - 1]:
            cache.append(val)
            n += 1
    while left_idx < left_n:
        var li = ts.at(ts.mi_row, ts.mi_col - 1)
        var val = ts.palette_colors[(li * 2 + plane) * PALETTE_COLORS + left_idx]
        left_idx += 1
        if n == 0 or val != cache[n - 1]:
            cache.append(val)
            n += 1
    return n


def sort_u8(mut a: List[UInt8], lo: Int, hi: Int):
    if lo >= hi:
        return
    var i = lo
    var j = hi
    var pivot = a[(lo + hi) >> 1]
    while i <= j:
        while a[i] < pivot:
            i += 1
        while a[j] > pivot:
            j -= 1
        if i <= j:
            var t = a[i]
            a[i] = a[j]
            a[j] = t
            i += 1
            j -= 1
    if lo < j:
        sort_u8(a, lo, j)
    if i < hi:
        sort_u8(a, i, hi)


def ceil_log2(x: Int) -> Int:
    if x <= 1:
        return 0
    var n = 0
    var v = 1
    while v < x:
        v <<= 1
        n += 1
    return n


def palette_tokens(mut ts: TileState) raises:
    var bh = block_height(ts.mi_size)
    var bw = block_width(ts.mi_size)
    var on_h = min_int(bh, (ts.mi_rows - ts.mi_row) * MI_SIZE)
    var on_w = min_int(bw, (ts.mi_cols - ts.mi_col) * MI_SIZE)
    if ts.palette_size_y > 0:
        var s = read_ns(ts, ts.palette_size_y)
        ts.color_map_y = zero_bytes(bh * bw)
        ts.color_map_y[0] = UInt8(s)
        for i in range(1, on_h + on_w - 1):
            var j = min_int(i, on_w - 1)
            while j >= max_int(0, i - on_h + 1):
                var order = get_palette_color_context(ts, ts.color_map_y, i - j, j, ts.palette_size_y)
                var pc = read_palette_color_idx(ts, ts.palette_size_y, order)
                ts.color_map_y[(i - j) * bw + j] = UInt8(pc)
                j -= 1
        for i in range(on_h):
            for j in range(on_w, bw):
                ts.color_map_y[i * bw + j] = ts.color_map_y[i * bw + on_w - 1]
        for i in range(on_h, bh):
            for j in range(bw):
                ts.color_map_y[i * bw + j] = ts.color_map_y[(on_h - 1) * bw + j]
        for v in ts.color_map_y:
            ts.color_maps.append(v)
    if ts.palette_size_uv > 0:
        var s = read_ns(ts, ts.palette_size_uv)
        var subx = 1 if ts.seq.subsampling_x else 0
        var suby = 1 if ts.seq.subsampling_y else 0
        bh = bh >> suby
        bw = bw >> subx
        on_h = on_h >> suby
        on_w = on_w >> subx
        if bw < 4:
            bw += 2
            on_w += 2
        if bh < 4:
            bh += 2
            on_h += 2
        ts.color_map_uv = zero_bytes(bh * bw)
        ts.color_map_uv[0] = UInt8(s)
        for i in range(1, on_h + on_w - 1):
            var j = min_int(i, on_w - 1)
            while j >= max_int(0, i - on_h + 1):
                var order = get_palette_color_context(ts, ts.color_map_uv, i - j, j, ts.palette_size_uv)
                var pc = read_palette_color_idx(ts, ts.palette_size_uv, order)
                ts.color_map_uv[(i - j) * bw + j] = UInt8(pc)
                j -= 1
        for i in range(on_h):
            for j in range(on_w, bw):
                ts.color_map_uv[i * bw + j] = ts.color_map_uv[i * bw + on_w - 1]
        for i in range(on_h, bh):
            for j in range(bw):
                ts.color_map_uv[i * bw + j] = ts.color_map_uv[(on_h - 1) * bw + j]
        for v in ts.color_map_uv:
            ts.color_maps.append(v)


def read_ns(mut ts: TileState, n: Int) raises -> Int:
    if n <= 0:
        return 0
    var w = 0
    while (1 << (w + 1)) <= n:
        w += 1
    var m = (1 << (w + 1)) - n
    var v = ts.sym.read_literal(w)
    if v < m:
        return v
    var extra = ts.sym.read_literal(1)
    return (v << 1) - m + extra


def get_palette_color_context(ts: TileState, cmap: List[UInt8], r: Int, c: Int, n: Int) -> List[Int]:
    var scores = fill_ints(PALETTE_COLORS, 0)
    var order = fill_ints(PALETTE_COLORS, 0)
    for i in range(PALETTE_COLORS):
        order[i] = i
    if c > 0:
        scores[Int(cmap[r * block_width(ts.mi_size) + c - 1])] += 2
    if r > 0 and c > 0:
        scores[Int(cmap[(r - 1) * block_width(ts.mi_size) + c - 1])] += 1
    if r > 0:
        scores[Int(cmap[(r - 1) * block_width(ts.mi_size) + c])] += 2
    for i in range(PALETTE_NUM_NEIGHBORS):
        var max_score = scores[i]
        var max_idx = i
        for j in range(i + 1, n):
            if scores[j] > max_score:
                max_score = scores[j]
                max_idx = j
        if max_idx != i:
            var ms = scores[max_idx]
            var mo = order[max_idx]
            var k = max_idx
            while k > i:
                scores[k] = scores[k - 1]
                order[k] = order[k - 1]
                k -= 1
            scores[i] = ms
            order[i] = mo
    var h = 0
    for i in range(PALETTE_NUM_NEIGHBORS):
        h += scores[i] * PALETTE_COLOR_HASH_MULTIPLIERS[i]
    if h < 0 or h >= len(PALETTE_COLOR_CONTEXT):
        h = 0
    return order


def read_palette_color_idx(mut ts: TileState, size: Int, order: List[Int]) -> Int:
    var ctx = 0
    var hash = 0
    for i in range(PALETTE_NUM_NEIGHBORS):
        hash += 0
    var table: List[UInt16]
    var n = 2
    if size == 2:
        table = ts.cdfs.palette_size_2_y_color
        n = PALETTE_SIZE_2_Y_COLOR_N
    elif size == 3:
        table = ts.cdfs.palette_size_3_y_color
        n = PALETTE_SIZE_3_Y_COLOR_N
    elif size == 4:
        table = ts.cdfs.palette_size_4_y_color
        n = PALETTE_SIZE_4_Y_COLOR_N
    elif size == 5:
        table = ts.cdfs.palette_size_5_y_color
        n = PALETTE_SIZE_5_Y_COLOR_N
    elif size == 6:
        table = ts.cdfs.palette_size_6_y_color
        n = PALETTE_SIZE_6_Y_COLOR_N
    elif size == 7:
        table = ts.cdfs.palette_size_7_y_color
        n = PALETTE_SIZE_7_Y_COLOR_N
    else:
        table = ts.cdfs.palette_size_8_y_color
        n = PALETTE_SIZE_8_Y_COLOR_N
    var off = ctx * (n + 1)
    if off + n + 1 > len(table):
        off = 0
    var c = cdf_row(table, off, n)
    var s = ts.sym.read_symbol(c, n)
    cdf_store(table, off, c, n)
    if s < 0 or s >= len(order):
        return 0
    return order[s]


