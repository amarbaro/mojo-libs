# Stand-in for Detections.get_anchors_coordinates on an axis-aligned xyxy box (no OBB, no mask).
# Swap for the S1 Detections method once lane-S1 logs READY.
from supervision.geometry.core import Point, Position


def box_anchor(x1: Float64, y1: Float64, x2: Float64, y2: Float64, p: Position) raises -> Point:
    var mx = (x1 + x2) / 2
    var my = (y1 + y2) / 2
    if p == Position.CENTER:
        return Point(mx, my)
    if p == Position.CENTER_LEFT:
        return Point(x1, my)
    if p == Position.CENTER_RIGHT:
        return Point(x2, my)
    if p == Position.BOTTOM_CENTER:
        return Point(mx, y2)
    if p == Position.BOTTOM_LEFT:
        return Point(x1, y2)
    if p == Position.BOTTOM_RIGHT:
        return Point(x2, y2)
    if p == Position.TOP_CENTER:
        return Point(mx, y1)
    if p == Position.TOP_LEFT:
        return Point(x1, y1)
    if p == Position.TOP_RIGHT:
        return Point(x2, y1)
    raise Error(p.name() + " is not supported.")
