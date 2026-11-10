"""Regenerate src/imkit/av1tab.mojo: every default CDF table of the AV1 spec (section 10, `Default_*_Cdf`) in the decoder's
stored form, and the 32 coefficient scan tables (`Default_Scan_*`, `Mrow_Scan_*`, `Mcol_Scan_*`, each checked to be a permutation). The spec writes each CDF as increasing cumulative values ending in 32768, then a 0 counter; the decoder
(src/imkit/av1sym.mojo) stores 32768 - value for each of the N entries and keeps the counter, so a row of N + 1 numbers
{c0 .. c(N-2), 32768, 0} becomes {32768 - c0 .. 32768 - c(N-2), 0, 0}. Each row is checked (non-decreasing, 32768 last,
counter 0) and each table's row length is checked to be constant. Build-time tool, nothing here runs at decode time.
usage: mojo run tools/av1_tables.mojo SPEC_TABLES_MD, the spec's 10.additional.tables.md from
       `gh api repos/AOMediaCodec/av1-spec/contents/10.additional.tables.md -H "Accept: application/vnd.github.raw" > FILE`."""
from std.sys import argv


def is_ident(c: UInt8) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def field_name(table: String) -> String:
    """Default_Intra_Frame_Y_Mode_Cdf -> intra_frame_y_mode."""
    var b = table.as_bytes()
    var out = List[UInt8]()
    for i in range(8, len(b) - 4):  # drop "Default_" and "_Cdf"
        var c = b[i]
        if c >= 65 and c <= 90:
            c += 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


struct Table(Copyable, Movable):
    var name: String
    var dims: String
    var row: Int  # N + 1
    var vals: List[Int]  # already in stored form

    def __init__(out self, var name: String, var dims: String, row: Int, var vals: List[Int]):
        self.name = name^
        self.dims = dims^
        self.row = row
        self.vals = vals^


def parse_table(b: Span[UInt8, _], start: Int, name: String) raises -> Table:
    """The table whose name starts at b[start]: dims up to ' =', then every innermost brace group as one row."""
    var i = start + name.byte_length()
    var d0 = i
    while b[i] != UInt8(ord("=")):
        i += 1
    var dims = String(unsafe_from_utf8=b[d0:i])
    while b[i] != UInt8(ord("{")):
        i += 1
    var depth = 0
    var vals = List[Int]()
    var row = -1
    var cur = List[Int]()
    var v, have, mul = 0, False, False  # the spec writes a few entries as products, `128 * 128`
    while True:
        var c = b[i]
        if c >= 48 and c <= 57:
            v = v * 10 + Int(c) - 48
            have = True
        else:
            if have:
                if mul:
                    cur[len(cur) - 1] *= v
                    mul = False
                else:
                    cur.append(v)
                v = 0
                have = False
            if c == UInt8(ord("*")):
                mul = True
            elif c == UInt8(ord("{")):
                depth += 1
                cur.clear()
            elif c == UInt8(ord("}")):
                if len(cur) > 0:
                    var n = len(cur)
                    if row < 0:
                        row = n
                    if n != row or n < 3:
                        raise Error("FAIL table " + name + ": row of " + String(n) + " after rows of " + String(row))
                    if cur[n - 1] != 0 or cur[n - 2] != 32768:
                        raise Error("FAIL table " + name + ": row does not end in 32768, 0")
                    for k in range(n - 1):
                        if k > 0 and cur[k] < cur[k - 1]:
                            raise Error("FAIL table " + name + ": decreasing row")
                        vals.append(32768 - cur[k])
                    vals.append(0)
                    cur.clear()
                depth -= 1
                if depth == 0:
                    break
        i += 1
    return Table(name, dims, row, vals^)


def parse_scan(b: Span[UInt8, _], start: Int, name: String) raises -> List[Int]:
    """A scan table: every number inside its braces; must be a permutation of 0 .. w*h - 1 (w x h from the name)."""
    var i = start + name.byte_length()
    while b[i] != UInt8(ord("{")):
        i += 1
    var vals = List[Int]()
    var v, have = 0, False
    while b[i] != UInt8(ord("}")):
        var c = b[i]
        if c >= 48 and c <= 57:
            v = v * 10 + Int(c) - 48
            have = True
        elif have:
            vals.append(v)
            v = 0
            have = False
        i += 1
    if have:
        vals.append(v)
    var seen = List[Bool](length=len(vals), fill=False)
    for x in vals:
        if x >= len(vals) or seen[x]:
            raise Error("FAIL scan " + name + ": not a permutation")
        seen[x] = True
    var dims = name.split("_")[2].split("x")
    if Int(dims[0]) * Int(dims[1]) != len(vals):
        raise Error("FAIL scan " + name + ": " + String(len(vals)) + " entries")
    return vals^


def emit_list(field: String, comment: String, vals: List[Int]) -> String:
    var s = "        self." + field + " = u16s(  # " + comment + "\n"
    var line = String()
    for n in vals:
        line += String(n) + " "
        if line.byte_length() > 104:
            s += "            \"" + line + "\"\n"
            line = String()
    if line.byte_length() > 0:
        s += "            \"" + line + "\"\n"
    return s + "        )\n"


def lower(name: String) -> String:
    var out = List[UInt8]()
    for c in name.as_bytes():
        out.append(c + 32 if c >= 65 and c <= 90 else c)
    return String(unsafe_from_utf8=Span(out))


def emit(t: Table) -> String:
    return emit_list(field_name(t.name), t.name + String(t.dims.strip()) + ", " + String(len(t.vals) // t.row) + " rows", t.vals)


def main() raises:
    var src: String
    with open(argv()[1], "r") as f:
        src = f.read()
    var b = src.as_bytes()
    var tables = List[Table]()
    var scan_names = List[String]()
    var scans = List[List[Int]]()
    var i = 0
    while True:
        var at = src.find("Default_", i)
        if at < 0:
            break
        var e = at
        while e < len(b) and is_ident(b[e]):
            e += 1
        i = e
        var name = String(unsafe_from_utf8=b[at:e])
        if (at == 0 or b[at - 1] == 10) and e < len(b) and b[e] == UInt8(ord("[")) and "_Scan_" in name:
            scan_names.append(name)
            scans.append(parse_scan(b, at, name))
            continue
        if (at > 0 and b[at - 1] != 10) or e >= len(b) or b[e] != UInt8(ord("[")) or not name.endswith("_Cdf"):
            continue  # a mention in the prose, not a definition
        tables.append(parse_table(b, at, name))
    for prefix in ["Mrow_Scan_", "Mcol_Scan_"]:
        var j = 0
        while True:
            var at = src.find(prefix, j)
            if at < 0:
                break
            var e = at
            while e < len(b) and is_ident(b[e]):
                e += 1
            j = e
            if (at == 0 or b[at - 1] == 10) and e < len(b) and b[e] == UInt8(ord("[")):
                var name = String(unsafe_from_utf8=b[at:e])
                scan_names.append(name)
                scans.append(parse_scan(b, at, name))
    if len(scans) != 32:
        raise Error("FAIL av1_tables: " + String(len(scans)) + " scan tables, expected 32")
    if len(tables) < 90:
        raise Error("FAIL av1_tables: only " + String(len(tables)) + " tables found")
    var s = String('"""AV1 default CDF and scan tables (spec section 10), generated by tools/av1_tables.mojo (do not edit).\n\n')
    s += "Stored form of src/imkit/av1sym.mojo: each CDF of N symbols is N + 1 UInt16, entry i = 32768 - spec value, entry N - 1 = 0,\n"
    s += "entry N = the adaptation counter (struct Cdfs). struct Scans holds the 32 scan orders.\n"
    s += "CDF detail: A table is flat in the spec's index order: row r of a table with row length L starts at r * L.\n"
    s += 'The constant `<NAME>_N` is N (symbols per CDF) for each field. Tables are text, parsed once by Cdfs()."""\n'
    s += "\n\ndef u16s(s: StringSlice) -> List[UInt16]:\n    \"\"\"Space separated integers to a list.\"\"\"\n"
    s += "    var r = List[UInt16]()\n    var v, have = 0, False\n    for b in s.as_bytes():\n"
    s += "        if b >= 48 and b <= 57:\n            v = v * 10 + Int(b) - 48\n            have = True\n"
    s += "        elif have:\n            r.append(UInt16(v))\n            v = 0\n            have = False\n    return r^\n\n"
    var total = 0
    for t in tables:
        s += "comptime " + field_name(t.name).upper() + "_N = " + String(t.row - 1) + "\n"
        total += len(t.vals)
    s += "\n\nstruct Cdfs(Copyable, Movable):\n    \"\"\"One field per spec default table, " + String(len(tables)) + " tables, " + String(total) + " entries.\"\"\"\n\n"
    for t in tables:
        s += "    var " + field_name(t.name) + ": List[UInt16]\n"
    s += "\n    def __init__(out self):\n"
    for t in tables:
        s += emit(t)
    s += "\n\nstruct Scans(Copyable, Movable):\n    \"\"\"The spec's coefficient scan orders (section 10), position k of the scan -> coefficient index.\"\"\"\n\n"
    for n in scan_names:
        s += "    var " + lower(n) + ": List[UInt16]\n"
    s += "\n    def __init__(out self):\n"
    for k in range(len(scans)):
        s += emit_list(lower(scan_names[k]), scan_names[k] + ", " + String(len(scans[k])) + " entries", scans[k])
    with open("src/imkit/av1tab.mojo", "w") as f:
        f.write(s)
    print("PASS av1_tables: " + String(len(tables)) + " CDF tables, " + String(total) + " entries, " + String(len(scans)) + " scans -> src/imkit/av1tab.mojo")
