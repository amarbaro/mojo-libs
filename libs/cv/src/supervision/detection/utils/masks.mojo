"""Mask helpers (port of supervision/detection/utils/masks.py). Masks are flat `List[UInt8]`, n x h x w.

Not ported (they need cv2 connected components, which mojo-cv does not expose yet): contains_holes,
contains_multiple_segments, filter_segments_by_distance.
"""


def count_mask_pixels(masks: List[UInt8], n: Int, pixels: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        var c = 0
        for p in range(pixels):
            c += Int(masks[i * pixels + p] != 0)
        out.append(c)
    return out^


def move_masks(masks: List[UInt8], n: Int, h: Int, w: Int, dx: Int, dy: Int, out_w: Int, out_h: Int) -> List[UInt8]:
    """Shift every mask by (dx, dy) into an out_h x out_w canvas; pixels shifted outside are dropped."""
    var out = List[UInt8]()
    for _ in range(n * out_h * out_w):
        out.append(0)
    for i in range(n):
        for y in range(h):
            var ty = y + dy
            if ty < 0 or ty >= out_h:
                continue
            for x in range(w):
                var tx = x + dx
                if tx < 0 or tx >= out_w:
                    continue
                out[i * out_h * out_w + ty * out_w + tx] = masks[i * h * w + y * w + x]
    return out^


def calculate_masks_centroids(masks: List[UInt8], n: Int, h: Int, w: Int) -> List[Int]:
    """(x, y) of every mask's centre of mass, truncated to int; (0, 0) for an empty mask."""
    var out = List[Int]()
    for i in range(n):
        var total = 0
        var sx = 0.0
        var sy = 0.0
        for y in range(h):
            for x in range(w):
                if masks[i * h * w + y * w + x] != 0:
                    total += 1
                    sx += Float64(x) + 0.5
                    sy += Float64(y) + 0.5
        var t = Float64(max(total, 1))
        out.append(Int(sx / t))
        out.append(Int(sy / t))
    return out^


def resize_masks(masks: List[UInt8], n: Int, h: Int, w: Int, max_dimension: Int = 640) -> Tuple[List[UInt8], Int, Int]:
    """Nearest-neighbour downscale so neither side exceeds max_dimension (np.linspace index grid)."""
    var scale = min(1.0, min(Float64(max_dimension) / Float64(h), Float64(max_dimension) / Float64(w)))
    if scale == 1.0:
        return (masks.copy(), h, w)
    var nh = max(1, Int(scale * Float64(h)))
    var nw = max(1, Int(scale * Float64(w)))
    var xs = List[Int]()
    for k in range(nw):
        xs.append(Int(Float64(k) * Float64(w - 1) / Float64(nw - 1)) if nw > 1 else 0)
    var ys = List[Int]()
    for k in range(nh):
        ys.append(Int(Float64(k) * Float64(h - 1) / Float64(nh - 1)) if nh > 1 else 0)
    var out = List[UInt8]()
    for i in range(n):
        for y in ys:
            for x in xs:
                out.append(masks[i * h * w + y * w + x])
    return (out^, nh, nw)


def mask_to_roi(mask: List[UInt8], h: Int, w: Int) -> Optional[Tuple[Int, Int, Int, Int]]:
    """(x1, y1, x2, y2) half open box around the True pixels of one mask, None when empty."""
    var x0 = w
    var y0 = h
    var x1 = -1
    var y1 = -1
    for y in range(h):
        for x in range(w):
            if mask[y * w + x] != 0:
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
    if x1 < 0:
        return None
    return (x0, y0, x1 + 1, y1 + 1)
