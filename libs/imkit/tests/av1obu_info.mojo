"""Print the AV1 sequence / frame header facts of an AVIF file.

Usage: av1obu_info FILE
"""

from std.sys import argv
from imkit.avif import avif_info
from imkit.av1obu import parse_av1


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: av1obu_info FILE")
        return
    var f = open(args[1], "r")
    var data = f.read_bytes()
    f.close()
    var info = avif_info(Span(data))
    if info.primary_len <= 0:
        raise Error("av1obu: empty primary item")
    var payload = List[UInt8]()
    for i in range(info.primary_len):
        payload.append(data[info.primary_off + i])
    var st = parse_av1(Span(payload))

    print("seq profile " + String(st.seq.profile))
    print("seq depth " + String(st.seq.bit_depth))

    var mono = "no"
    if st.seq.mono_chrome:
        mono = "yes"
    print("seq mono " + mono)

    var sx = 0
    if st.seq.subsampling_x:
        sx = 1
    var sy = 0
    if st.seq.subsampling_y:
        sy = 1
    print("seq subsampling " + String(sx) + " " + String(sy))

    var ftype = "KEY"
    if st.frame.frame_type == 2:
        ftype = "INTRA_ONLY"
    print("frame type " + ftype)

    print("frame size " + String(st.frame.upscaled_width) + "x" + String(st.frame.height))
    print("tiles " + String(st.frame.tile_info.cols) + "x" + String(st.frame.tile_info.rows))
    print("base_q_idx " + String(st.frame.base_q_idx))

    var line = "tile_bytes "
    for i in range(len(st.tile_sizes)):
        if i > 0:
            line += ","
        line += String(st.tile_sizes[i])
    print(line)
