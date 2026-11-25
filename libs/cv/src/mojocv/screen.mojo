# screen: the one screen parser (R13a, R13b and R20a of the full-stack plan) and the stuck-state check (R13a).
#   screenParse OUT IMG [lang=ignored ocr=1 scale=3 q=0]   elements of a screenshot: box, role, clickable, text
#   screenStuck OUT A B [thr=16 minfrac=0.005 q=0]      did anything meaningful change between two captures?
# Parse: flat-colour regions (4-connected pixels of one colour, `q` low bits dropped) whose bounding box edge is covered by the
# region itself are the widgets: a frame (a one to few pixel border) or a filled rectangle, the pair of both being one box. The
# largest flat region (at least 40 % of the picture) is the screen background and is not an element; a region of 90 % or more of
# the picture is never one. Ink = pixels of a widget that differ from its fill by more than 40 in some channel (the frame colour
# is not ink), outside its child widgets; ink rows form lines (a gap of up to 2 empty rows stays one line), a column gap wider
# than the line height splits a line. Each line is read by screen-ocr as one process (a difference image: dark ink on
# white whatever the colours, scaled by `scale`). Roles: button (a leaf widget with one line of text, 14 to 80 px tall, 1.2 to 6
# times as wide, at most a tenth of the picture; clickable), dialog (a widget with a button among its children; its first line,
# in the top quarter, is its title and its text), panel (any other widget), text (a line outside a button).
# Boxes are x0 y0 x1 y1 with x1 and y1 exclusive. Flat colour means a screenshot, not a photograph; a gradient or a JPEG needs q.
# Limits (measured on the fs-h2 set only): no text outside a widget on a non-flat background; two columns of text with a gap
# narrower than the line height are one line; overlapping widgets are not separated.
# Stuck: a pixel is changed when any channel moved by more than `thr`. With a dialog in A, only changes inside it count (a modal
# blocks what lies behind it); without one, the whole picture. Progress = the changed share of that region reaches `minfrac`. One
# pair cannot tell a blinking cursor from a one-pixel progress bar by its size alone: the share rule calls both not progress.
# Outputs. screenParse: OUT int32 N x 6 (x0 y0 x1 y1 role clickable; roles 0 panel 1 dialog 2 button 3 text), OUT.1 uint8 N x 96
# (the text, UTF-8, zero padded), OUT.json the same as text. screenStuck: OUT int32 1 x 2 (progress, stuck), OUT.1 int32 1 x 4
# (bounding box of all changed pixels), OUT.2 int32 1 x 6 (dialog found, its box, changed pixels inside it).
from std.subprocess import run as sh_run
from mojocv.mat import Mat, load, save
from mojocv.core import Args, peek_code
from mojocv.imgproc import resize

comptime U8 = DType.uint8
comptime I32 = DType.int32
comptime PANEL = 0
comptime DIALOG = 1
comptime BUTTON = 2
comptime TEXT = 3
comptime TXT = 96  # bytes per text row in OUT.1
comptime INK = 40


@fieldwise_init
struct Widget(Copyable, Movable):
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int
    var fill: Int  # packed colour of the interior, -1 unknown
    var ring: Int  # packed colour of the frame, -1 none
    var role: Int
    var text: String
    var parent: Int


@fieldwise_init
struct Elem(Copyable, Movable):
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int
    var role: Int
    var text: String


def _key(m: Mat[U8], i: Int, q: Int) -> Int:
    """The packed colour of pixel i (row-major index) with the low q bits of each channel dropped."""
    if m.ch >= 3:
        var b = i * m.ch
        return (Int(m.data[b] >> UInt8(q)) << 16) | (Int(m.data[b + 1] >> UInt8(q)) << 8) | Int(m.data[b + 2] >> UInt8(q))
    var v = Int(m.data[i * m.ch] >> UInt8(q))
    return (v << 16) | (v << 8) | v


def _find(mut p: List[Int32], i: Int) -> Int:
    var r = i
    while Int(p[r]) != r:
        p[r] = p[Int(p[r])]
        r = Int(p[r])
    return r


def _dist(m: Mat[U8], i: Int, fill: Int) -> Int:
    """The largest channel difference between pixel i and the packed colour `fill` (q = 0)."""
    var d = 0
    if m.ch >= 3:
        var b = i * m.ch
        d = max(abs(Int(m.data[b]) - (fill >> 16)), max(abs(Int(m.data[b + 1]) - ((fill >> 8) & 255)), abs(Int(m.data[b + 2]) - (fill & 255))))
    else:
        d = abs(Int(m.data[i]) - (fill & 255))
    return d


struct Cand(Copyable, Movable):
    var x0: Int
    var y0: Int
    var x1: Int  # exclusive
    var y1: Int
    var key: Int
    var area: Int
    var frame: Bool  # the region is a frame (a hollow rectangle), not a filled one

    def __init__(out self, x0: Int, y0: Int, x1: Int, y1: Int, key: Int, area: Int, frame: Bool):
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.key = key
        self.area = area
        self.frame = frame


def flat_regions(m: Mat[U8], q: Int, mut bg: Int) -> List[Cand]:
    """Rectangular flat-colour regions: a region qualifies when its own pixels cover at least three of its four bounding-box
    edges to 95 % (the fourth to 50 %: text can run over one border). `bg` receives the colour of the largest region of at least
    40 % of the picture, -1 when there is none."""
    var rows = m.rows
    var cols = m.cols
    var n = rows * cols
    var par = List[Int32](length=n, fill=0)
    for i in range(n):
        par[i] = Int32(i)
    var keys = List[Int32](length=n, fill=0)
    for i in range(n):
        keys[i] = Int32(_key(m, i, q))
    for y in range(rows):
        for x in range(cols):
            var i = y * cols + x
            if x > 0 and keys[i] == keys[i - 1]:
                var a = _find(par, i)
                var b = _find(par, i - 1)
                if a != b:
                    par[max(a, b)] = Int32(min(a, b))
            if y > 0 and keys[i] == keys[i - cols]:
                var a = _find(par, i)
                var b = _find(par, i - cols)
                if a != b:
                    par[max(a, b)] = Int32(min(a, b))
    var cid = List[Int32](length=n, fill=-1)
    var rx0 = List[Int32]()
    var ry0 = List[Int32]()
    var rx1 = List[Int32]()
    var ry1 = List[Int32]()
    var area = List[Int32]()
    var rkey = List[Int32]()
    for i in range(n):
        var r = _find(par, i)
        if Int(cid[r]) < 0:
            cid[r] = Int32(len(area))
            rx0.append(Int32(cols))
            ry0.append(Int32(rows))
            rx1.append(-1)
            ry1.append(-1)
            area.append(0)
            rkey.append(keys[r])
        var c = Int(cid[r])
        var x = i % cols
        var y = i // cols
        rx0[c] = min(rx0[c], Int32(x))
        ry0[c] = min(ry0[c], Int32(y))
        rx1[c] = max(rx1[c], Int32(x))
        ry1[c] = max(ry1[c], Int32(y))
        area[c] += 1
    var k = len(area)
    var top = List[Int32](length=k, fill=0)
    var bot = List[Int32](length=k, fill=0)
    var lef = List[Int32](length=k, fill=0)
    var rig = List[Int32](length=k, fill=0)
    for i in range(n):
        var c = Int(cid[_find(par, i)])
        var x = i % cols
        var y = i // cols
        if y == Int(ry0[c]):
            top[c] += 1
        if y == Int(ry1[c]):
            bot[c] += 1
        if x == Int(rx0[c]):
            lef[c] += 1
        if x == Int(rx1[c]):
            rig[c] += 1
    var out = List[Cand]()
    bg = -1
    var bga = 0
    for c in range(k):
        var w = Int(rx1[c] - rx0[c]) + 1
        var h = Int(ry1[c] - ry0[c]) + 1
        var a = Int(area[c])
        if a * 10 >= n * 4 and a > bga:
            bg = Int(rkey[c])
            bga = a
        if w < 12 or h < 12 or a < 150 or a * 10 >= n * 9:
            continue
        var ef = List[Float64]()
        ef.append(Float64(top[c]) / Float64(w))
        ef.append(Float64(bot[c]) / Float64(w))
        ef.append(Float64(lef[c]) / Float64(h))
        ef.append(Float64(rig[c]) / Float64(h))
        var full = 0
        var low = 1.0
        for e in ef:
            if e >= 0.95:
                full += 1
            low = min(low, e)
        if full < 3 or low < 0.5:
            continue
        out.append(Cand(Int(rx0[c]), Int(ry0[c]), Int(rx1[c]) + 1, Int(ry1[c]) + 1, Int(rkey[c]), a, Float64(a) < 0.55 * Float64(w * h)))
    return out^


def _inside(a: Cand, b: Cand, slack: Int) -> Bool:
    """Box a lies within box b, each side at most `slack` px in from b's side."""
    return a.x0 >= b.x0 and a.y0 >= b.y0 and a.x1 <= b.x1 and a.y1 <= b.y1 and a.x0 - b.x0 <= slack and a.y0 - b.y0 <= slack and b.x1 - a.x1 <= slack and b.y1 - a.y1 <= slack


def widgets(m: Mat[U8], q: Int, mut bg: Int) -> List[Widget]:
    """Frames and fills merged into boxes (a fill at most 4 px inside a frame is that frame's interior), identical nested boxes dropped,
    sorted by area, largest first."""
    var cs = flat_regions(m, q, bg)
    var out = List[Widget]()
    var used = List[Bool](length=len(cs), fill=False)
    for i in range(len(cs)):
        if not cs[i].frame:
            continue
        var fill = -1
        for j in range(len(cs)):
            if not cs[j].frame and not used[j] and _inside(cs[j], cs[i], 4):
                fill = cs[j].key
                used[j] = True
                break
        out.append(Widget(cs[i].x0, cs[i].y0, cs[i].x1, cs[i].y1, fill, cs[i].key, PANEL, String(""), -1))
    for j in range(len(cs)):
        if not cs[j].frame and not used[j]:
            out.append(Widget(cs[j].x0, cs[j].y0, cs[j].x1, cs[j].y1, cs[j].key, -1, PANEL, String(""), -1))
    # a frame without a recorded fill: the colour just inside its corner
    for i in range(len(out)):
        if out[i].fill < 0:
            var cx = min(out[i].x0 + 3, m.cols - 1)
            var cy = min(out[i].y0 + 3, m.rows - 1)
            out[i].fill = _key(m, cy * m.cols + cx, 0)
    var order = List[Int]()
    for i in range(len(out)):
        order.append((out[i].x1 - out[i].x0) * (out[i].y1 - out[i].y0) * 65536 + i)
    sort(order)
    var res = List[Widget]()
    for k in range(len(order) - 1, -1, -1):
        res.append(out[order[k] % 65536].copy())
    return res^


struct Line(Copyable, Movable):
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int

    def __init__(out self, x0: Int, y0: Int, x1: Int, y1: Int):
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1


def _in_any(boxes: List[Widget], kids: List[Int], x: Int, y: Int) -> Bool:
    for k in kids:
        if x >= boxes[k].x0 and x < boxes[k].x1 and y >= boxes[k].y0 and y < boxes[k].y1:
            return True
    return False


def text_lines(m: Mat[U8], ws: List[Widget], kids: List[Int], x0: Int, y0: Int, x1: Int, y1: Int, fill: Int, ring: Int, q: Int) -> List[Line]:
    """Ink lines inside the box (x0, y0, x1, y1): pixels that differ from `fill` by more than INK, are not `ring`, and lie outside
    the child widgets `kids`."""
    var w = x1 - x0
    var h = y1 - y0
    var ink = List[UInt8](length=w * h, fill=0)
    var rowc = List[Int](length=h, fill=0)
    for y in range(h):
        for x in range(w):
            var i = (y0 + y) * m.cols + x0 + x
            if _dist(m, i, fill) > INK and _key(m, i, q) != ring and not _in_any(ws, kids, x0 + x, y0 + y):
                ink[y * w + x] = 1
                rowc[y] += 1
    var out = List[Line]()
    var y = 0
    while y < h:
        if rowc[y] == 0:
            y += 1
            continue
        var ya = y
        var yb = y
        var gap = 0
        while y < h and gap <= 2:
            if rowc[y] > 0:
                yb = y
                gap = 0
            else:
                gap += 1
            y += 1
        # columns of the band, split where an empty gap is wider than the band is tall
        var colc = List[Int](length=w, fill=0)
        for yy in range(ya, yb + 1):
            for x in range(w):
                colc[x] += Int(ink[yy * w + x])
        var split = max(10, yb - ya + 1)
        var x = 0
        while x < w:
            if colc[x] == 0:
                x += 1
                continue
            var xa = x
            var xb = x
            var g = 0
            while x < w and g <= split:
                if colc[x] > 0:
                    xb = x
                    g = 0
                else:
                    g += 1
                x += 1
            var n = 0
            var ra = yb + 1
            var rb = ya - 1
            for yy in range(ya, yb + 1):
                for xx in range(xa, xb + 1):
                    if ink[yy * w + xx] == 1:
                        n += 1
                        ra = min(ra, yy)
                        rb = max(rb, yy)
            if n >= 8:
                out.append(Line(x0 + xa, y0 + ra, x0 + xb + 1, y0 + rb + 1))
    return out^


def ocr_line(m: Mat[U8], ws: List[Widget], kids: List[Int], ln: Line, fill: Int, ring: Int, q: Int, scale: Int, lang: String, tmp: String) raises -> String:
    """Read one line with screen-ocr (RapidOCR; `lang` is unused): a difference image (dark ink on white), `scale` times larger, 8 px of white around."""
    var pad = 2
    var x0 = max(ln.x0 - pad, 0)
    var y0 = max(ln.y0 - pad, 0)
    var x1 = min(ln.x1 + pad, m.cols)
    var y1 = min(ln.y1 + pad, m.rows)
    var cw = x1 - x0
    var ch = y1 - y0
    var d = List[Int](length=cw * ch, fill=0)
    var mx = 1
    for y in range(ch):
        for x in range(cw):
            var i = (y0 + y) * m.cols + x0 + x
            if _key(m, i, q) != ring and not _in_any(ws, kids, x0 + x, y0 + y):
                var v = _dist(m, i, fill)
                d[y * cw + x] = v
                mx = max(mx, v)
    var g = Mat[U8](ch, cw, 1)
    for i in range(cw * ch):
        g.data[i] = UInt8(255 - d[i] * 255 // mx)
    var big = resize[U8](g, cw * scale, ch * scale, 2)
    var bw = big.cols + 16 * scale
    var bh = big.rows + 16 * scale
    var pgm = List[UInt8]()
    for b in String("P5\n" + String(bw) + " " + String(bh) + "\n255\n").as_bytes():
        pgm.append(b)
    var body = List[UInt8](length=bw * bh, fill=255)
    for y in range(big.rows):
        for x in range(big.cols):
            body[(y + 8 * scale) * bw + x + 8 * scale] = big.data[y * big.cols + x]
    pgm.extend(body^)
    with open(tmp, "w") as f:
        f.write_bytes(Span(pgm))
    var raw = sh_run("screen-ocr '" + tmp + "' 2>/dev/null | sed 's/^[^|]*| //' | tr '\\n' ' ' | tr -s ' ' || true")
    var keep = List[UInt8]()
    for b in raw.as_bytes():
        if b != 10 and b != 12 and b != 13:
            keep.append(b)
    return String(String(unsafe_from_utf8=Span(keep)).strip())


def parse(m: Mat[U8], q: Int, ocr: Bool, scale: Int, lang: String, tmp: String) raises -> List[Elem]:
    var bg = -1
    var ws = widgets(m, q, bg)
    var nw = len(ws)
    # parents: the smallest widget that contains it (the list is largest first, so the last container found is the smallest)
    for i in range(nw):
        for j in range(i):
            if ws[j].x0 <= ws[i].x0 and ws[j].y0 <= ws[i].y0 and ws[j].x1 >= ws[i].x1 and ws[j].y1 >= ws[i].y1 and not (ws[j].x0 == ws[i].x0 and ws[j].y0 == ws[i].y0 and ws[j].x1 == ws[i].x1 and ws[j].y1 == ws[i].y1):
                ws[i].parent = j
    var out = List[Elem]()
    var frame_area = m.rows * m.cols
    var tlines = List[List[Line]]()
    var ttexts = List[List[String]]()
    # lines and text per widget (children first is not needed: the roles come after)
    for i in range(nw):
        var kids = List[Int]()
        for j in range(nw):
            if ws[j].parent == i:
                kids.append(j)
        var ls = text_lines(m, ws, kids, ws[i].x0, ws[i].y0, ws[i].x1, ws[i].y1, ws[i].fill, ws[i].ring, q)
        var tx = List[String]()
        var keep = List[Line]()
        for ln in ls:
            var t = ocr_line(m, ws, kids, ln, ws[i].fill, ws[i].ring, q, scale, lang, tmp) if ocr else String("?")
            if t.byte_length() > 0:
                tx.append(t)
                keep.append(ln.copy())
        tlines.append(keep^)
        ttexts.append(tx^)
    # roles, smallest widgets first so that a parent sees its children's roles
    for i in range(nw - 1, -1, -1):
        var nk = 0
        var nb = 0
        for j in range(nw):
            if ws[j].parent == i:
                nk += 1
                if ws[j].role == BUTTON:
                    nb += 1
        var w = ws[i].x1 - ws[i].x0
        var h = ws[i].y1 - ws[i].y0
        if nk == 0 and len(tlines[i]) == 1 and h >= 14 and h <= 80 and 10 * w >= 12 * h and w <= 6 * h and 10 * w * h <= frame_area:
            ws[i].role = BUTTON
        elif nb > 0:
            ws[i].role = DIALOG
    for i in range(nw):
        var first = 0
        if ws[i].role == DIALOG and len(tlines[i]) > 0 and (tlines[i][0].y0 - ws[i].y0) * 4 < (ws[i].y1 - ws[i].y0):
            ws[i].text = ttexts[i][0].copy()
            first = 1
        elif ws[i].role == BUTTON:
            ws[i].text = ttexts[i][0].copy()
            first = len(tlines[i])
        out.append(Elem(ws[i].x0, ws[i].y0, ws[i].x1, ws[i].y1, ws[i].role, ws[i].text.copy()))
        for k in range(first, len(tlines[i])):
            out.append(Elem(tlines[i][k].x0, tlines[i][k].y0, tlines[i][k].x1, tlines[i][k].y1, TEXT, ttexts[i][k].copy()))
    # text on the screen background (outside every widget)
    if bg >= 0:
        var top = List[Int]()
        for i in range(nw):
            if ws[i].parent < 0:
                top.append(i)
        var ls = text_lines(m, ws, top, 0, 0, m.cols, m.rows, bg, -1, q)
        for ln in ls:
            var t = ocr_line(m, ws, top, ln, bg, -1, q, scale, lang, tmp) if ocr else String("?")
            if t.byte_length() > 0:
                out.append(Elem(ln.x0, ln.y0, ln.x1, ln.y1, TEXT, t^))
    return out^


def _json_str(s: String) -> String:
    var o = List[UInt8]()
    o.append(34)
    for b in s.as_bytes():
        if b == 34 or b == 92:
            o.append(92)
            o.append(b)
        elif b < 32:
            o.append(32)
        else:
            o.append(b)
    o.append(34)
    return String(unsafe_from_utf8=Span(o))


def write_elems(es: List[Elem], path: String) raises:
    var n = len(es)
    var t = Mat[I32](n, 6, 1)
    var s = Mat[U8](n, TXT, 1)
    var js = String("[")
    var names = List[String]()
    names.append("panel")
    names.append("dialog")
    names.append("button")
    names.append("text")
    for i in range(n):
        t.data[6 * i] = Int32(es[i].x0)
        t.data[6 * i + 1] = Int32(es[i].y0)
        t.data[6 * i + 2] = Int32(es[i].x1)
        t.data[6 * i + 3] = Int32(es[i].y1)
        t.data[6 * i + 4] = Int32(es[i].role)
        t.data[6 * i + 5] = Int32(1 if es[i].role == BUTTON else 0)
        var bs = es[i].text.as_bytes()
        var m = min(len(bs), TXT - 1)
        while m > 0 and m < len(bs) and (bs[m] & 0xC0) == 0x80:  # never cut a UTF-8 sequence
            m -= 1
        for k in range(m):
            s.data[i * TXT + k] = bs[k]
        js += ("" if i == 0 else ",\n ") + "{\"role\":\"" + names[es[i].role] + "\",\"box\":[" + String(es[i].x0) + "," + String(es[i].y0) + "," + String(es[i].x1) + "," + String(es[i].y1) + "],\"clickable\":" + ("true" if es[i].role == BUTTON else "false") + ",\"text\":" + _json_str(es[i].text) + "}"
    save(t, path)
    save(s, path + ".1")
    with open(path + ".json", "w") as f:
        f.write(js + "]\n")


def stuck(a: Mat[U8], b: Mat[U8], thr: Int, minfrac: Float64, q: Int) raises -> Tuple[Mat[I32], Mat[I32], Mat[I32]]:
    if not a.same_shape(b):
        raise Error("screenStuck: the two captures differ in shape")
    var dx0 = 0
    var dy0 = 0
    var dx1 = 0
    var dy1 = 0
    var found = 0
    var best = 0
    # a dialog = the largest widget with a button-like child, found through the same parse without OCR
    var es = parse(a, q, False, 1, String("eng"), String(""))
    for e in es:
        var ar = (e.x1 - e.x0) * (e.y1 - e.y0)
        if e.role == DIALOG and ar > best:
            best = ar
            found = 1
            dx0 = e.x0
            dy0 = e.y0
            dx1 = e.x1
            dy1 = e.y1
    var bx0 = a.cols
    var by0 = a.rows
    var bx1 = 0
    var by1 = 0
    var inside = 0
    var total = 0
    for y in range(a.rows):
        for x in range(a.cols):
            var i = (y * a.cols + x) * a.ch
            var d = 0
            for c in range(a.ch):
                d = max(d, abs(Int(a.data[i + c]) - Int(b.data[i + c])))
            if d > thr:
                total += 1
                bx0 = min(bx0, x)
                by0 = min(by0, y)
                bx1 = max(bx1, x + 1)
                by1 = max(by1, y + 1)
                if found == 1 and x >= dx0 and x < dx1 and y >= dy0 and y < dy1:
                    inside += 1
    if total == 0:
        bx0 = 0
        by0 = 0
    var region = (dx1 - dx0) * (dy1 - dy0) if found == 1 else a.rows * a.cols
    var changed = inside if found == 1 else total
    var progress = 1 if Float64(changed) >= minfrac * Float64(region) and changed > 0 else 0
    var r0 = Mat[I32](1, 2, 1)
    r0.data[0] = Int32(progress)
    r0.data[1] = Int32(1 - progress)
    var r1 = Mat[I32](1, 4, 1)
    r1.data[0] = Int32(bx0)
    r1.data[1] = Int32(by0)
    r1.data[2] = Int32(bx1)
    r1.data[3] = Int32(by1)
    var r2 = Mat[I32](1, 6, 1)
    r2.data[0] = Int32(found)
    r2.data[1] = Int32(dx0)
    r2.data[2] = Int32(dy0)
    r2.data[3] = Int32(dx1)
    r2.data[4] = Int32(dy1)
    r2.data[5] = Int32(inside)
    return (r0^, r1^, r2^)


def run(mut a: Args) raises -> Bool:
    if a.op != "screenParse" and a.op != "screenStuck":
        return False
    var need = 1 if a.op == "screenParse" else 2
    if len(a.ins) != need:
        raise Error(a.op + ": needs " + String(need) + " uint8 picture(s)")
    for p in a.ins:
        if peek_code(p) != 0:
            raise Error(a.op + ": uint8 pictures only")
    var q = a.i("q", 0)
    if a.op == "screenParse":
        var lang = a.s("lang", "deu")
        for b in lang.as_bytes():
            if not ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 43 or b == 95):
                raise Error("screenParse: lang is letters, digits, + and _")
        var m = load[U8](a.ins[0])
        var es = List[Elem]()
        while a.again():
            es = parse(m, q, a.i("ocr", 1) == 1, a.i("scale", 3), lang, a.out + ".ocr.pgm")
        write_elems(es, a.out)
        _ = sh_run("rm -f '" + a.out + ".ocr.pgm'")
        return True
    var x = load[U8](a.ins[0])
    var y = load[U8](a.ins[1])
    var r = (Mat[I32](0, 0), Mat[I32](0, 0), Mat[I32](0, 0))
    while a.again():
        r = stuck(x, y, a.i("thr", 16), a.f("minfrac", 0.005), q)
    save(r[0], a.out)
    save(r[1], a.out + ".1")
    save(r[2], a.out + ".2")
    return True
