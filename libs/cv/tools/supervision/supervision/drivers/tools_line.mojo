from json import Json, parse
from supervision.detection.tools.anchors import box_anchor
from supervision.detection.tools.line_zone import LineZone, ClassCount
from supervision.geometry.core import Point, Position
from rowio import read_rows


def bools(v: List[Bool]) -> Json:
    var a = Json.array()
    for b in v:
        a.push(Json.of(b))
    return a^


def counts(c: ClassCount) -> Json:
    var a = Json.array()
    for j in range(len(c.keys)):
        var pair = Json.array()
        if c.keys[j]:
            pair.push(Json.of(c.keys[j].value()))
        else:
            pair.push(Json())
        pair.push(Json.of(c.counts[j]))
        a.push(pair^)
    return a^


def run(args: Json) raises -> Json:
    var s = args.get("start")
    var e = args.get("end")
    var zone = LineZone(Point(s.at(0).num(), s.at(1).num()), Point(e.at(0).num(), e.at(1).num()),
                        args.get("min_threshold").int())
    var names = args.get("anchors")
    var positions = List[Position]()
    for k in range(names.len()):
        positions.append(Position.from_name(names.at(k).str()))
    var frames = args.get("frames")
    var out = Json.array()
    for f in range(frames.len()):
        var fr = frames.at(f)
        var boxes = fr.get("xyxy")
        var n = boxes.len()
        var anchors = List[List[Point]]()
        for p in positions:
            var col = List[Point]()
            for i in range(n):
                var b = boxes.at(i)
                col.append(box_anchor(b.at(0).num(), b.at(1).num(), b.at(2).num(), b.at(3).num(), p))
            anchors.append(col^)
        var tids = List[Int]()
        var has_t = not fr.get("tracker_id").is_null()
        if has_t:
            for i in range(n):
                tids.append(fr.get("tracker_id").at(i).int())
        var cids = List[Int]()
        var has_c = not fr.get("class_id").is_null()
        if has_c:
            for i in range(n):
                cids.append(fr.get("class_id").at(i).int())
        var r = zone.trigger(n, anchors, has_t, tids, has_c, cids)
        var o = Json.object()
        o.set("in", bools(r[0]))
        o.set("out", bools(r[1]))
        out.push(o^)
    var fin = Json.object()
    fin.set("in_count", Json.of(zone.in_count()))
    fin.set("out_count", Json.of(zone.out_count()))
    fin.set("in_per_class", counts(zone.in_counts))
    fin.set("out_per_class", counts(zone.out_counts))
    out.push(fin^)
    return out^


def main() raises:
    for row in read_rows():
        var cols = row.split("\t")
        var res: Json
        try:
            res = run(parse(String(cols[1])))
        except:
            res = Json.object()
            res.set("error", Json.of(String("ValueError")))
        print(res.dumps())
