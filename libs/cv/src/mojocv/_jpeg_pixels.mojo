"""The ISLOW transform and BGR packing for the baseline JPEG decoder.

The integer butterfly and chroma weights are adapted from the in-tree
imkit/jpeg.mojo (the IJG slow integer transform and fancy upsampling).
"""
from std.math import clamp
from mojocv.mat import Mat

comptime _I8 = SIMD[DType.int32, 8]
comptime _U8 = SIMD[DType.uint8, 8]
comptime _BytePtr = Pointer[UInt8, MutAnyOrigin]


@always_inline
def _transpose(a: Array[_I8, 8]) -> Array[_I8, 8]:
    var pairs = Array[_I8, 8](uninitialized=True)
    var quads = Array[_I8, 8](uninitialized=True)
    var output = Array[_I8, 8](uninitialized=True)
    comptime for i in range(4):
        var left, right = a[2*i], a[2*i+1]
        pairs[2*i] = left.shuffle[0,8,1,9,2,10,3,11](right)
        pairs[2*i+1] = left.shuffle[4,12,5,13,6,14,7,15](right)
    comptime for i in range(2):
        comptime for j in range(2):
            var left, right = pairs[4*i+j], pairs[4*i+2+j]
            quads[4*i+2*j] = left.shuffle[0,1,8,9,2,3,10,11](right)
            quads[4*i+2*j+1] = left.shuffle[4,5,12,13,6,7,14,15](right)
    comptime for i in range(4):
        var left, right = quads[i], quads[4+i]
        output[2*i] = left.shuffle[0,1,2,3,8,9,10,11](right)
        output[2*i+1] = left.shuffle[4,5,6,7,12,13,14,15](right)
    return output^


@always_inline
def _pass[shift: Int](mut w: Array[_I8, 8]):
    var z2 = w[2]
    var z3 = w[6]
    var z1 = (z2 + z3) * 4433
    var t2 = z1 - z3 * 15137
    var t3 = z1 + z2 * 6270
    var t0 = (w[0] + w[4]) << 13
    var t1 = (w[0] - w[4]) << 13
    var t10 = t0 + t3
    var t13 = t0 - t3
    var t11 = t1 + t2
    var t12 = t1 - t2
    var a0 = w[7]
    var a1 = w[5]
    var a2 = w[3]
    var a3 = w[1]
    z1 = (a0 + a3) * -7373
    z2 = (a1 + a2) * -20995
    z3 = a0 + a2
    var z4 = a1 + a3
    var z5 = (z3 + z4) * 9633
    z3 = z3 * -16069 + z5
    z4 = z4 * -3196 + z5
    a0 = a0 * 2446 + z1 + z3
    a1 = a1 * 16819 + z2 + z4
    a2 = a2 * 25172 + z2 + z3
    a3 = a3 * 12299 + z1 + z4
    var bias = _I8(1 << (shift - 1))
    w[0] = (t10 + a3 + bias) >> _I8(shift)
    w[7] = (t10 - a3 + bias) >> _I8(shift)
    w[1] = (t11 + a2 + bias) >> _I8(shift)
    w[6] = (t11 - a2 + bias) >> _I8(shift)
    w[2] = (t12 + a1 + bias) >> _I8(shift)
    w[5] = (t12 - a1 + bias) >> _I8(shift)
    w[3] = (t13 + a0 + bias) >> _I8(shift)
    w[4] = (t13 - a0 + bias) >> _I8(shift)


@always_inline
def _clip(v: _I8) -> _U8:
    return clamp(v, _I8(0), _I8(255)).cast[DType.uint8]()


@always_inline
def _write_dc(value: Int32, dst: _BytePtr, stride: Int):
    var row = _clip(_I8(((value + 4) >> 3) + 128))
    comptime for r in range(8):
        dst.unsafe_store(r * stride, row)


@always_inline
def _write_block(mut coeff: Array[_I8, 8], dst: _BytePtr, stride: Int):
    _pass[11](coeff)
    var w = _transpose(coeff)
    _pass[18](w)
    var rows = _transpose(w)
    comptime for r in range(8):
        dst.unsafe_store(r * stride, _clip(rows[r] + 128))


@always_inline
def _packed(dst: _BytePtr, x: Int, b: _U8, g: _U8, r: _U8):
    # Arrange exactly eight BGR pixels without writing past the row.
    var channels = b.join(g).join(r.join(_U8(0)))
    var p = dst.unsafe_offset(3*x)
    var pixels = channels.shuffle[0,8,16,1,9,17,2,10,18,3,11,19,4,12,20,5,
                                  13,21,6,14,22,7,15,23,24,25,26,27,28,29,30,31]()
    p.unsafe_store(0, pixels.slice[16]())
    p.unsafe_store(16, pixels.slice[8, offset=16]())


@always_inline
def _color(l: _I8, cb: _I8, cr: _I8, dst: _BytePtr, x: Int):
    var r = _clip(l + ((91881 * cr + 32768) >> 16))
    var g = _clip(l + ((-22554 * cb - 46802 * cr + 32768) >> 16))
    var b = _clip(l + ((116130 * cb + 32768) >> 16))
    _packed(dst, x, b, g, r)


@always_inline
def _center(ch: _BytePtr, other: _BytePtr, x: Int, vertical: Bool) -> _I8:
    var c = ch.unsafe_load[width=8](x).cast[DType.int32]()
    if vertical:
        return 3 * c + other.unsafe_load[width=8](x).cast[DType.int32]()
    return 4 * c


def _upsample(ch: _BytePtr, other: _BytePtr, output: _BytePtr, n: Int, vertical: Bool):
    # IJG uses box upsampling if the chroma row has at most two samples.
    if n <= 2:
        for i in range(n):
            output[unsafe_offset=2*i] = ch[unsafe_offset=i]
            output[unsafe_offset=2*i+1] = ch[unsafe_offset=i]
        return
    var even_bias = _I8(8 if vertical else 4)
    var odd_bias = _I8(7 if vertical else 8)
    var x = 0
    for i in range(8, n - 8, 8):
        var a = _center(ch, other, i - 1, vertical)
        var b = _center(ch, other, i, vertical) * 3
        var c = _center(ch, other, i + 1, vertical)
        var even = ((b + a + even_bias) >> 4).cast[DType.uint8]()
        var odd = ((b + c + odd_bias) >> 4).cast[DType.uint8]()
        output.unsafe_store(2*i, even.join(odd).shuffle[0,8,1,9,2,10,3,11,4,12,5,13,6,14,7,15]())
        x = i + 8
    for region in range(2):
        var start, end = (0, min(x, 8)) if region == 0 else (x, n)
        for i in range(start, end):
            var lo, hi = max(i - 1, 0), min(i + 1, n - 1)
            var a, b, c = Int(ch[unsafe_offset=lo]), Int(ch[unsafe_offset=i]), Int(ch[unsafe_offset=hi])
            if vertical:
                a, b, c = 3*a + Int(other[unsafe_offset=lo]), 3*b + Int(other[unsafe_offset=i]), 3*c + Int(other[unsafe_offset=hi])
            else:
                a, b, c = 4*a, 4*b, 4*c
            output[unsafe_offset=2*i] = UInt8((3*b + a + Int(even_bias[0])) >> 4)
            output[unsafe_offset=2*i+1] = UInt8((3*b + c + Int(odd_bias[0])) >> 4)


def _render_row[mode: Int](dst: _BytePtr, l: _BytePtr, u: _BytePtr, v: _BytePtr, width: Int):
    var end = width & -8
    for x in range(0, end, 8):
        var y = l.unsafe_load[width=8](x)
        comptime if mode == 1:
            _packed(dst, x, y, y, y)
        else:
            var cb = u.unsafe_load[width=8](x)
            var cr = v.unsafe_load[width=8](x)
            comptime if mode == 0:
                _color(y.cast[DType.int32](), cb.cast[DType.int32]() - 128, cr.cast[DType.int32]() - 128, dst, x)
            else:
                _packed(dst, x, cr, cb, y)
    for x in range(end, width):
        var a = l[unsafe_offset=x]
        comptime if mode == 1:
            dst[unsafe_offset=3*x], dst[unsafe_offset=3*x+1], dst[unsafe_offset=3*x+2] = a, a, a
        elif mode == 2:
            dst[unsafe_offset=3*x], dst[unsafe_offset=3*x+1], dst[unsafe_offset=3*x+2] = v[unsafe_offset=x], u[unsafe_offset=x], a
        else:
            var cb, cr = Int(u[unsafe_offset=x]) - 128, Int(v[unsafe_offset=x]) - 128
            var y = Int(a)
            dst[unsafe_offset=3*x] = UInt8(clamp(y + ((116130 * cb + 32768) >> 16), 0, 255))
            dst[unsafe_offset=3*x+1] = UInt8(clamp(y + ((-22554 * cb - 46802 * cr + 32768) >> 16), 0, 255))
            dst[unsafe_offset=3*x+2] = UInt8(clamp(y + ((91881 * cr + 32768) >> 16), 0, 255))
