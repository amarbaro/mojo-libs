"""AV1 tile syntax state (stage 4a): spec tables, per-tile state, block records."""
from std.collections import List
from imkit.av1sym import SymbolDecoder
from imkit.av1tab import Cdfs, Scans
from imkit.av1obu import Av1Stream, SequenceHeader, FrameHeader

# ---- spec symbolic constants (section 3, section 6) ----
comptime BLOCK_4X4 = 0
comptime BLOCK_4X8 = 1
comptime BLOCK_8X4 = 2
comptime BLOCK_8X8 = 3
comptime BLOCK_8X16 = 4
comptime BLOCK_16X8 = 5
comptime BLOCK_16X16 = 6
comptime BLOCK_16X32 = 7
comptime BLOCK_32X16 = 8
comptime BLOCK_32X32 = 9
comptime BLOCK_32X64 = 10
comptime BLOCK_64X32 = 11
comptime BLOCK_64X64 = 12
comptime BLOCK_64X128 = 13
comptime BLOCK_128X64 = 14
comptime BLOCK_128X128 = 15
comptime BLOCK_4X16 = 16
comptime BLOCK_16X4 = 17
comptime BLOCK_8X32 = 18
comptime BLOCK_32X8 = 19
comptime BLOCK_16X64 = 20
comptime BLOCK_64X16 = 21
comptime BLOCK_INVALID = 22
comptime BLOCK_SIZES = 22

comptime PARTITION_NONE = 0
comptime PARTITION_HORZ = 1
comptime PARTITION_VERT = 2
comptime PARTITION_SPLIT = 3
comptime PARTITION_HORZ_A = 4
comptime PARTITION_HORZ_B = 5
comptime PARTITION_VERT_A = 6
comptime PARTITION_VERT_B = 7
comptime PARTITION_HORZ_4 = 8
comptime PARTITION_VERT_4 = 9

comptime TX_4X4 = 0
comptime TX_8X8 = 1
comptime TX_16X16 = 2
comptime TX_32X32 = 3
comptime TX_64X64 = 4
comptime TX_4X8 = 5
comptime TX_8X4 = 6
comptime TX_8X16 = 7
comptime TX_16X8 = 8
comptime TX_16X32 = 9
comptime TX_32X16 = 10
comptime TX_32X64 = 11
comptime TX_64X32 = 12
comptime TX_4X16 = 13
comptime TX_16X4 = 14
comptime TX_8X32 = 15
comptime TX_32X8 = 16
comptime TX_16X64 = 17
comptime TX_64X16 = 18
comptime TX_SIZES_ALL = 19

comptime DC_PRED = 0
comptime V_PRED = 1
comptime H_PRED = 2
comptime D45_PRED = 3
comptime D135_PRED = 4
comptime D113_PRED = 5
comptime D157_PRED = 6
comptime D203_PRED = 7
comptime D67_PRED = 8
comptime SMOOTH_PRED = 9
comptime SMOOTH_V_PRED = 10
comptime SMOOTH_H_PRED = 11
comptime PAETH_PRED = 12
comptime UV_CFL_PRED = 13
comptime INTRA_MODES = 13

comptime INTRA_FRAME = 0
comptime NONE_FRAME = -1

comptime SEG_LVL_ALT_Q = 0
comptime SEG_LVL_ALT_LF_Y_V = 1
comptime SEG_LVL_ALT_LF_Y_H = 2
comptime SEG_LVL_ALT_LF_U = 3
comptime SEG_LVL_ALT_LF_V = 4
comptime SEG_LVL_REF_FRAME = 5
comptime SEG_LVL_SKIP = 6
comptime SEG_LVL_GLOBALMV = 7
comptime SEG_LVL_MAX = 8

comptime RESTORE_NONE = 0
comptime RESTORE_WIENER = 1
comptime RESTORE_SGRPROJ = 2
comptime RESTORE_SWITCHABLE = 3

comptime TX_MODE_ONLY_4X4 = 0
comptime TX_MODE_LARGEST = 1
comptime TX_MODE_SELECT = 2

comptime MAX_VARTX_DEPTH = 2
comptime MAX_TX_DEPTH = 2
comptime MI_SIZE = 4
comptime MI_SIZE_LOG2 = 2
comptime MAX_SEGMENTS = 8
comptime FRAME_LF_COUNT = 4
comptime MAX_LOOP_FILTER = 63
comptime DELTA_Q_SMALL = 3
comptime DELTA_LF_SMALL = 3
comptime PALETTE_COLORS = 8
comptime PALETTE_NUM_NEIGHBORS = 3
comptime PALETTE_COLOR_CONTEXTS = 5
comptime PALETTE_MAX_COLOR_CONTEXT_HASH = 8
comptime CFL_ALPHABET_SIZE = 16
comptime CFL_JOINT_SIGNS = 8
comptime CFL_SIGN_ZERO = 0
comptime CFL_SIGN_NEG = 1
comptime CFL_SIGN_POS = 2
comptime MV_JOINT_HZVNZ = 0
comptime MV_JOINT_HNZVZ = 1
comptime MV_JOINT_HZVNZ_HNZVZ = 2
comptime MV_CLASS_0 = 0
comptime CLASS0_SIZE = 2
comptime MV_INTRABC_CONTEXT = 1
comptime INTRABC_DELAY_PIXELS = 256
comptime MAX_TILE_WIDTH = 4096
comptime MAX_TILE_AREA = 4096 * 2304
comptime MAX_TILE_COLS = 64
comptime MAX_TILE_ROWS = 64
comptime SUPERRES_NUM = 8
comptime SGRPROJ_PARAMS_BITS = 4
comptime SGRPROJ_PRJ_SUBEXP_K = 4
comptime SGRPROJ_PRJ_BITS = 7
comptime SGRPROJ_XQD_MID0 = -32
comptime SGRPROJ_XQD_MID1 = 31
comptime WIENER_TAPS_MID0 = 3
comptime WIENER_TAPS_MID1 = -7
comptime WIENER_TAPS_MID2 = 15

# ---- section 9.3 conversion tables ----
comptime BLOCK_WIDTH = [4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 32, 64, 64, 64, 128, 128, 4, 16, 8, 32, 16, 64]
comptime BLOCK_HEIGHT = [4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 64, 32, 64, 128, 64, 128, 16, 4, 32, 8, 64, 16]
comptime MI_WIDTH_LOG2 = [0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 0, 2, 1, 3, 2, 4]
comptime MI_HEIGHT_LOG2 = [0, 1, 0, 1, 2, 1, 2, 3, 2, 3, 4, 3, 4, 5, 4, 5, 2, 0, 3, 1, 4, 2]
comptime NUM_4X4_WIDE = [1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 1, 4, 2, 8, 4, 16]
comptime NUM_4X4_HIGH = [1, 2, 1, 2, 4, 2, 4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 4, 1, 8, 2, 16, 4]
comptime SIZE_GROUP = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 0, 0, 1, 1, 2, 2]

comptime MAX_TX_SIZE_RECT = [
    TX_4X4, TX_4X8, TX_8X4, TX_8X8, TX_8X16, TX_16X8, TX_16X16,
    TX_16X32, TX_32X16, TX_32X32, TX_32X64, TX_64X32, TX_64X64,
    TX_64X64, TX_64X64, TX_64X64, TX_4X16, TX_16X4, TX_8X32,
    TX_32X8, TX_16X64, TX_64X16,
]
comptime MAX_TX_DEPTH_TABLE = [0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4, 4, 2, 2, 3, 3, 4, 4]

comptime SPLIT_TX_SIZE = [
    TX_4X4, TX_4X4, TX_8X8, TX_16X16, TX_32X32,
    TX_4X4, TX_4X4, TX_8X8, TX_8X8, TX_16X16,
    TX_16X16, TX_32X32, TX_32X32, TX_4X8, TX_8X4,
    TX_8X16, TX_16X8, TX_16X32, TX_32X16,
]
comptime TX_WIDTH = [4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64]
comptime TX_HEIGHT = [4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16]
comptime TX_WIDTH_LOG2 = [2, 3, 4, 5, 6, 2, 3, 3, 4, 4, 5, 5, 6, 2, 4, 3, 5, 4, 6]
comptime TX_HEIGHT_LOG2 = [2, 3, 4, 5, 6, 3, 2, 4, 3, 5, 4, 6, 5, 4, 2, 5, 3, 6, 4]
comptime TX_SIZE_SQR = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_64X64,
    TX_4X4, TX_4X4, TX_8X8, TX_8X8, TX_16X16,
    TX_16X16, TX_32X32, TX_32X32, TX_4X4, TX_4X4,
    TX_8X8, TX_8X8, TX_16X16, TX_16X16,
]
comptime TX_SIZE_SQR_UP = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_64X64,
    TX_8X8, TX_8X8, TX_16X16, TX_16X16, TX_32X32,
    TX_32X32, TX_64X64, TX_64X64, TX_16X16, TX_16X16,
    TX_32X32, TX_32X32, TX_64X64, TX_64X64,
]
comptime ADJUSTED_TX_SIZE = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_32X32,
    TX_4X8, TX_8X4, TX_8X16, TX_16X8, TX_16X32,
    TX_32X16, TX_32X32, TX_32X32, TX_4X16, TX_16X4,
    TX_8X32, TX_32X8, TX_16X32, TX_32X16,
]
comptime INTRA_MODE_CONTEXT = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0]
comptime PALETTE_COLOR_HASH_MULTIPLIERS = [1, 2, 2]
comptime PALETTE_COLOR_CONTEXT = [0, 1, 2, 3, 4, 0, 1, 2, 3]

comptime SGR_PARAMS = [
    140, 3236, 112, 156, 107, 3277, 112, 156,
    107, 3277, 112, 156, 139, 3236, 112, 156,
]
comptime WIENER_TAPS_MIN = [-5, -23, -17]
comptime WIENER_TAPS_MAX = [10, 8, 46]
comptime WIENER_TAPS_K = [1, 2, 3]
comptime SGRPROJ_XQD_MIN = [-96, -32]
comptime SGRPROJ_XQD_MAX = [31, 95]


def zeros(n: Int) -> List[Int]:
    var r = List[Int]()
    for _ in range(n):
        r.append(0)
    return r^


def fill_ints(n: Int, v: Int) -> List[Int]:
    var r = List[Int]()
    for _ in range(n):
        r.append(v)
    return r^


def zero_bytes(n: Int) -> List[UInt8]:
    var r = List[UInt8]()
    for _ in range(n):
        r.append(UInt8(0))
    return r^


def cdf_row(table: List[UInt16], off: Int, n: Int) -> List[UInt16]:
    var r = List[UInt16]()
    for i in range(n + 1):
        r.append(table[off + i])
    return r^


def cdf_store(mut table: List[UInt16], off: Int, row: List[UInt16], n: Int):
    for i in range(n + 1):
        table[off + i] = row[i]


def block_width(b: Int) -> Int:
    return BLOCK_WIDTH[b]


def block_height(b: Int) -> Int:
    return BLOCK_HEIGHT[b]


def num_4x4_wide(b: Int) -> Int:
    return NUM_4X4_WIDE[b]


def num_4x4_high(b: Int) -> Int:
    return NUM_4X4_HIGH[b]


def tx_width(t: Int) -> Int:
    return TX_WIDTH[t]


def tx_height(t: Int) -> Int:
    return TX_HEIGHT[t]


def tx_width_log2(t: Int) -> Int:
    return TX_WIDTH_LOG2[t]


def tx_height_log2(t: Int) -> Int:
    return TX_HEIGHT_LOG2[t]


def partition_subsize(partition: Int, bsize: Int) -> Int:
    """Partition_Subsize for square bSize, section 9.3."""
    if partition == PARTITION_NONE:
        return bsize
    var w = BLOCK_WIDTH[bsize]
    var h = BLOCK_HEIGHT[bsize]
    if partition == PARTITION_HORZ:
        if h < 8:
            return BLOCK_INVALID
        return block_from_dims(w, h >> 1)
    if partition == PARTITION_VERT:
        if w < 8:
            return BLOCK_INVALID
        return block_from_dims(w >> 1, h)
    if partition == PARTITION_SPLIT:
        if w < 8 or h < 8:
            return BLOCK_INVALID
        return block_from_dims(w >> 1, h >> 1)
    if partition == PARTITION_HORZ_A or partition == PARTITION_HORZ_B:
        if h < 16:
            return BLOCK_INVALID
        return block_from_dims(w, h >> 1)
    if partition == PARTITION_VERT_A or partition == PARTITION_VERT_B:
        if w < 16:
            return BLOCK_INVALID
        return block_from_dims(w >> 1, h)
    if partition == PARTITION_HORZ_4:
        if h < 16:
            return BLOCK_INVALID
        return block_from_dims(w, h >> 2)
    if partition == PARTITION_VERT_4:
        if w < 16:
            return BLOCK_INVALID
        return block_from_dims(w >> 2, h)
    return BLOCK_INVALID


def block_from_dims(w: Int, h: Int) -> Int:
    for b in range(BLOCK_SIZES):
        if BLOCK_WIDTH[b] == w and BLOCK_HEIGHT[b] == h:
            return b
    return BLOCK_INVALID


def subsampled_size(bsize: Int, sub_x: Bool, sub_y: Bool) -> Int:
    var w = BLOCK_WIDTH[bsize]
    var h = BLOCK_HEIGHT[bsize]
    if sub_x:
        w = w >> 1
    if sub_y:
        h = h >> 1
    if w < 4:
        w = 4
    if h < 4:
        h = 4
    return block_from_dims(w, h)


def is_directional_mode(mode: Int) -> Bool:
    return mode >= V_PRED and mode <= D67_PRED


@fieldwise_init
struct TileStats(Copyable, Movable):
    var blocks: Int
    var mi_covered: Int
    var mi_total: Int
    var tx_blocks: Int
    var nonzero: Int
    var skip: Int
    var intrabc: Int
    var palette: Int
    var cfl: Int
    var filter_intra: Int

    def __init__(out self):
        self.blocks = 0
        self.mi_covered = 0
        self.mi_total = 0
        self.tx_blocks = 0
        self.nonzero = 0
        self.skip = 0
        self.intrabc = 0
        self.palette = 0
        self.cfl = 0
        self.filter_intra = 0


@fieldwise_init
struct BlockInfo(Copyable, Movable):
    var mi_row: Int
    var mi_col: Int
    var mi_size: Int
    var segment_id: Int
    var skip: Bool
    var qindex: Int
    var use_intrabc: Bool
    var mv_row: Int
    var mv_col: Int
    var y_mode: Int
    var uv_mode: Int
    var angle_delta_y: Int
    var angle_delta_uv: Int
    var cfl_alpha_u: Int
    var cfl_alpha_v: Int
    var use_filter_intra: Bool
    var filter_intra_mode: Int
    var palette_size_y: Int
    var palette_size_uv: Int
    var palette_colors_y: List[UInt8]
    var palette_colors_u: List[UInt8]
    var palette_colors_v: List[UInt8]
    var color_map_offset: Int
    var tx_size: Int

    def __init__(out self):
        self.mi_row = 0
        self.mi_col = 0
        self.mi_size = 0
        self.segment_id = 0
        self.skip = False
        self.qindex = 0
        self.use_intrabc = False
        self.mv_row = 0
        self.mv_col = 0
        self.y_mode = 0
        self.uv_mode = 0
        self.angle_delta_y = 0
        self.angle_delta_uv = 0
        self.cfl_alpha_u = 0
        self.cfl_alpha_v = 0
        self.use_filter_intra = False
        self.filter_intra_mode = 0
        self.palette_size_y = 0
        self.palette_size_uv = 0
        self.palette_colors_y = List[UInt8]()
        self.palette_colors_u = List[UInt8]()
        self.palette_colors_v = List[UInt8]()
        self.color_map_offset = 0
        self.tx_size = 0


struct TileState(Movable):
    var sym: SymbolDecoder
    var cdfs: Cdfs
    var scans: Scans
    var seq: SequenceHeader
    var frame: FrameHeader
    var mi_cols: Int
    var mi_rows: Int
    var mi_col_start: Int
    var mi_col_end: Int
    var mi_row_start: Int
    var mi_row_end: Int
    var mi_stride: Int
    var stats: TileStats
    var blocks: List[BlockInfo]
    var color_maps: List[UInt8]

    var mi_sizes: List[Int]
    var y_modes: List[Int]
    var uv_modes: List[Int]
    var ref_frames: List[Int]
    var is_inters: List[Int]
    var skip_modes: List[Int]
    var skips: List[Int]
    var tx_sizes: List[Int]
    var inter_tx_sizes: List[Int]
    var palette_sizes: List[Int]
    var palette_colors: List[Int]
    var segment_ids: List[Int]
    var comp_group_idxs: List[Int]
    var compound_idxs: List[Int]

    var above_level: List[Int]
    var above_dc: List[Int]
    var left_level: List[Int]
    var left_dc: List[Int]
    var above_seg_pred: List[Int]
    var left_seg_pred: List[Int]

    var delta_lf: List[Int]
    var current_qindex: Int
    var cdef_idx: List[Int]
    var ref_lr_wiener: List[Int]
    var ref_sgr_xqd: List[Int]

    var mi_row: Int
    var mi_col: Int
    var mi_size: Int
    var has_chroma: Bool
    var avail_u: Bool
    var avail_l: Bool
    var avail_u_chroma: Bool
    var avail_l_chroma: Bool
    var y_mode: Int
    var uv_mode: Int
    var angle_delta_y: Int
    var angle_delta_uv: Int
    var cfl_alpha_u: Int
    var cfl_alpha_v: Int
    var use_filter_intra: Bool
    var filter_intra_mode: Int
    var palette_size_y: Int
    var palette_size_uv: Int
    var palette_colors_y: List[UInt8]
    var palette_colors_u: List[UInt8]
    var palette_colors_v: List[UInt8]
    var color_map_y: List[UInt8]
    var color_map_uv: List[UInt8]
    var segment_id: Int
    var lossless: Bool
    var skip: Bool
    var skip_mode: Bool
    var is_inter: Bool
    var use_intrabc: Bool
    var mv_row: Int
    var mv_col: Int
    var tx_size: Int
    var read_deltas: Bool
    var coded_lossless: Bool
    var seg_id_pre_skip: Bool
    var last_active_seg_id: Int

    def __init__(out self, st: Av1Stream, tile_index: Int) raises:
        var ti = st.frame.tile_info.copy()
        var nc = len(ti.mi_col_starts)
        var nr = len(ti.mi_row_starts)
        if nc < 2 or nr < 2:
            raise Error("av1tile: bad tile grid")
        self.mi_cols = ti.mi_col_starts[nc - 1]
        self.mi_rows = ti.mi_row_starts[nr - 1]
        self.mi_stride = self.mi_cols + 2
        var total = (self.mi_rows + 2) * self.mi_stride
        self.mi_col_start = ti.mi_col_starts[tile_index % ti.cols]
        self.mi_col_end = ti.mi_col_starts[(tile_index % ti.cols) + 1]
        var tr = tile_index // ti.cols
        self.mi_row_start = ti.mi_row_starts[tr]
        self.mi_row_end = ti.mi_row_starts[tr + 1]
        if st.tile_offs[tile_index] < 0 or st.tile_sizes[tile_index] < 0:
            raise Error("av1tile: bad tile offset")
        var end = st.tile_offs[tile_index] + st.tile_sizes[tile_index]
        if end > len(st.data):
            raise Error("av1tile: tile beyond data")
        self.sym = SymbolDecoder(Span(st.data), st.tile_offs[tile_index], end)
        self.cdfs = Cdfs()
        self.scans = Scans()
        self.seq = st.seq.copy()
        self.frame = st.frame.copy()
        self.stats = TileStats()
        self.stats.mi_total = (self.mi_col_end - self.mi_col_start) * (self.mi_row_end - self.mi_row_start)
        self.blocks = List[BlockInfo]()
        self.color_maps = List[UInt8]()

        self.mi_sizes = zeros(total)
        self.y_modes = zeros(total)
        self.uv_modes = zeros(total)
        self.ref_frames = zeros(total * 2)
        self.is_inters = zeros(total)
        self.skip_modes = zeros(total)
        self.skips = zeros(total)
        self.tx_sizes = zeros(total)
        self.inter_tx_sizes = zeros(total)
        self.palette_sizes = zeros(total * 2)
        self.palette_colors = zeros(total * 2 * PALETTE_COLORS)
        self.segment_ids = zeros(total)
        self.comp_group_idxs = zeros(total)
        self.compound_idxs = zeros(total)

        var aw = self.mi_cols + 2
        var ah = self.mi_rows + 2
        self.above_level = zeros(3 * aw)
        self.above_dc = zeros(3 * aw)
        self.left_level = zeros(3 * ah)
        self.left_dc = zeros(3 * ah)
        self.above_seg_pred = zeros(aw)
        self.left_seg_pred = zeros(ah)

        self.delta_lf = zeros(FRAME_LF_COUNT)
        self.current_qindex = st.frame.base_q_idx
        self.cdef_idx = fill_ints(total, -1)
        self.ref_lr_wiener = zeros(3 * 2 * 3)
        self.ref_sgr_xqd = zeros(3 * 2)
        for p in range(3):
            for pass_i in range(2):
                for i in range(3):
                    self.ref_lr_wiener[(p * 2 + pass_i) * 3 + i] = [WIENER_TAPS_MID0, WIENER_TAPS_MID1, WIENER_TAPS_MID2][i]
                self.ref_sgr_xqd[p * 2 + pass_i] = [SGRPROJ_XQD_MID0, SGRPROJ_XQD_MID1][pass_i]

        self.mi_row = 0
        self.mi_col = 0
        self.mi_size = BLOCK_4X4
        self.has_chroma = False
        self.avail_u = False
        self.avail_l = False
        self.avail_u_chroma = False
        self.avail_l_chroma = False
        self.y_mode = DC_PRED
        self.uv_mode = DC_PRED
        self.angle_delta_y = 0
        self.angle_delta_uv = 0
        self.cfl_alpha_u = 0
        self.cfl_alpha_v = 0
        self.use_filter_intra = False
        self.filter_intra_mode = 0
        self.palette_size_y = 0
        self.palette_size_uv = 0
        self.palette_colors_y = List[UInt8]()
        self.palette_colors_u = List[UInt8]()
        self.palette_colors_v = List[UInt8]()
        self.color_map_y = List[UInt8]()
        self.color_map_uv = List[UInt8]()
        self.segment_id = 0
        self.lossless = False
        self.skip = False
        self.skip_mode = False
        self.is_inter = False
        self.use_intrabc = False
        self.mv_row = 0
        self.mv_col = 0
        self.tx_size = TX_4X4
        self.read_deltas = False
        self.coded_lossless = st.frame.coded_lossless
        self.seg_id_pre_skip = False
        self.last_active_seg_id = 0
        self.init_segmentation()

    def init_segmentation(mut self):
        if not self.frame.segmentation_enabled:
            self.seg_id_pre_skip = False
            self.last_active_seg_id = 0
            return
        self.last_active_seg_id = 0
        for s in range(MAX_SEGMENTS):
            for f in range(SEG_LVL_MAX):
                if self.seg_feature_enabled(s, f):
                    self.last_active_seg_id = s
        self.seg_id_pre_skip = self.seg_feature_enabled(0, SEG_LVL_SKIP)

    def seg_feature_enabled(self, seg: Int, feature: Int) -> Bool:
        if not self.frame.segmentation_enabled:
            return False
        var idx = seg * SEG_LVL_MAX + feature
        if idx < 0 or idx >= len(self.frame.seg_feature_enabled):
            return False
        return self.frame.seg_feature_enabled[idx]

    def seg_feature_data_at(self, seg: Int, feature: Int) -> Int:
        var idx = seg * SEG_LVL_MAX + feature
        if idx < 0 or idx >= len(self.frame.seg_feature_data):
            return 0
        return self.frame.seg_feature_data[idx]

    def get_qindex(self, seg: Int) -> Int:
        var q = self.frame.base_q_idx
        if self.seg_feature_enabled(seg, SEG_LVL_ALT_Q):
            q += self.seg_feature_data_at(seg, SEG_LVL_ALT_Q)
        if q < 0:
            q = 0
        if q > 255:
            q = 255
        return q

    def seg_feature_active(self, feature: Int) -> Bool:
        return self.seg_feature_enabled(self.segment_id, feature)

    def at(self, r: Int, c: Int) -> Int:
        return r * self.mi_stride + c

    def in_tile(self, r: Int, c: Int) -> Bool:
        return r >= self.mi_row_start and r < self.mi_row_end and c >= self.mi_col_start and c < self.mi_col_end

    def above_plane(self, plane: Int, c: Int) -> Int:
        var sub_x = 0
        if plane > 0:
            if self.seq.subsampling_x:
                sub_x = 1
        return plane * (self.mi_cols + 2) + (c >> sub_x)

    def left_plane(self, plane: Int, r: Int) -> Int:
        var sub_y = 0
        if plane > 0:
            if self.seq.subsampling_y:
                sub_y = 1
        return plane * (self.mi_rows + 2) + (r >> sub_y)

    def clear_above_context(mut self):
        for i in range(len(self.above_level)):
            self.above_level[i] = 0
            self.above_dc[i] = 0
        for i in range(len(self.above_seg_pred)):
            self.above_seg_pred[i] = 0

    def clear_left_context(mut self):
        for i in range(len(self.left_level)):
            self.left_level[i] = 0
            self.left_dc[i] = 0
        for i in range(len(self.left_seg_pred)):
            self.left_seg_pred[i] = 0

    def clear_cdef(self, r: Int, c: Int):
        if r < 0 or c < 0 or r >= self.mi_rows or c >= self.mi_cols:
            return
        self.cdef_idx[self.at(r, c)] = -1
        if self.seq.use_128x128_superblock:
            var s4 = num_4x4_wide(BLOCK_64X64)
            if r + s4 < self.mi_rows and c + s4 < self.mi_cols:
                self.cdef_idx[self.at(r, c + s4)] = -1
                self.cdef_idx[self.at(r + s4, c)] = -1
                self.cdef_idx[self.at(r + s4, c + s4)] = -1

    def read_cdf_row(mut self, table: List[UInt16], off: Int, n: Int) raises -> Int:
        var c = cdf_row(table, off, n)
        var s = self.sym.read_symbol(c, n)
        cdf_store(table, off, c, n)
        return s
