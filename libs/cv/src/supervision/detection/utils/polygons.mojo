"""polygon_to_mask of supervision/detection/utils/converters.py, on the cv2 layer (supervision._cv.draw.fill_poly)."""

from mojocv.mat import Mat
from supervision._cv.draw import fill_poly
from supervision.detection.utils.converters import MIN_POLYGON_POINT_COUNT


def polygon_to_mask(polygon: List[Float64], width: Int, height: Int) -> List[UInt8]:
    """(height x width) 0/1 mask of the polygon given as flat (x, y) pairs; coordinates truncate to int like astype(int32).
    Fewer than three points gives an empty mask."""
    var m = Mat[DType.uint8](height, width, 1)
    var n = len(polygon) // 2
    if n >= MIN_POLYGON_POINT_COUNT:
        var xs = List[Int]()
        var ys = List[Int]()
        for i in range(n):
            xs.append(Int(polygon[2 * i]))
            ys.append(Int(polygon[2 * i + 1]))
        fill_poly(m, [xs^], [ys^], [1.0])
    var out = List[UInt8]()
    for i in range(height * width):
        out.append(UInt8(m.data[i]))
    return out^
