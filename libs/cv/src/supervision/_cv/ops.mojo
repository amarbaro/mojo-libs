# Pixel ops of cv2's core/imgproc that supervision calls and mojo-cv lacks: addWeighted, convertScaleAbs, applyColorMap(JET).
from mojocv.mat import Mat
from mojocv.imgproc import rint
from supervision._cv.jet import JET_TEXT

comptime Img = Mat[DType.uint8]


def _sat(v: Float32) -> UInt8:
    var r = rint(Float64(v))
    return UInt8(0 if r < 0 else (255 if r > 255 else r))


def add_weighted(a: Img, alpha: Float64, b: Img, beta: Float64, gamma: Float64) raises -> Img:
    """cv2.addWeighted on uint8: saturate(round(a*alpha + b*beta + gamma)) in float32."""
    if not a.same_shape(b):
        raise Error("add_weighted: shapes differ")
    var out = Img(a.rows, a.cols, a.ch)
    var al = Float32(alpha)
    var be = Float32(beta)
    var ga = Float32(gamma)
    for i in range(a.size()):
        out.data[i] = _sat(Float32(a.data[i]) * al + Float32(b.data[i]) * be + ga)
    return out^


def convert_scale_abs(a: Img, alpha: Float64, beta: Float64) -> Img:
    """cv2.convertScaleAbs on uint8: saturate(round(|a*alpha + beta|)) in float32."""
    var out = Img(a.rows, a.cols, a.ch)
    var al = Float32(alpha)
    var be = Float32(beta)
    for i in range(a.size()):
        var v = Float32(a.data[i]) * al + be
        out.data[i] = _sat(-v if v < 0 else v)
    return out^


def apply_color_map_jet(gray: Img) raises -> Img:
    """cv2.applyColorMap(gray, COLORMAP_JET): 1-channel uint8 in, BGR out."""
    var lut = List[UInt8]()
    for tok in String(JET_TEXT).split(" "):
        if tok.byte_length() > 0:
            for c in tok.split(","):
                lut.append(UInt8(atol(String(c))))
    if gray.ch != 1:
        raise Error("apply_color_map: wants a 1-channel image")
    var out = Img(gray.rows, gray.cols, 3)
    for i in range(gray.size()):
        for k in range(3):
            out.data[i * 3 + k] = lut[Int(gray.data[i]) * 3 + k]
    return out^
