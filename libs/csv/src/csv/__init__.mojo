

comptime QUOTE_MINIMAL = 0
comptime QUOTE_ALL = 1
comptime QUOTE_NONNUMERIC = 2
comptime QUOTE_NONE = 3
comptime QUOTE_STRINGS = 4
comptime QUOTE_NOTNULL = 5

comptime START_RECORD = 0
comptime START_FIELD = 1
comptime ESCAPED_CHAR = 2
comptime IN_FIELD = 3
comptime IN_QUOTED_FIELD = 4
comptime ESCAPE_IN_QUOTED_FIELD = 5
comptime QUOTE_IN_QUOTED_FIELD = 6
comptime EAT_CRNL = 7
comptime AFTER_ESCAPED_CRNL = 8

struct Dialect(Copyable, Movable):
    var delimiter: UInt8
    var quotechar: UInt8
    var escapechar: UInt8
    var has_escape: Bool
    var doublequote: Bool
    var skipinitialspace: Bool
    var strict: Bool
    var quoting: Int
    var lineterminator: List[UInt8]

    def __init__(out self, delimiter: UInt8 = UInt8(ord(",")), quotechar: UInt8 = UInt8(ord('"')), escapechar: UInt8 = 0, has_escape: Bool = False, doublequote: Bool = True, skipinitialspace: Bool = False, strict: Bool = False, quoting: Int = QUOTE_MINIMAL):
        self.delimiter = delimiter
        self.quotechar = quotechar
        self.escapechar = escapechar
        self.has_escape = has_escape
        self.doublequote = doublequote
        self.skipinitialspace = skipinitialspace
        self.strict = strict
        self.quoting = quoting
        self.lineterminator = List[UInt8]()
        self.lineterminator.append(UInt8(13))
        self.lineterminator.append(UInt8(10))

    @staticmethod
    def excel() -> Dialect:
        return Dialect()

    @staticmethod
    def excel_tab() -> Dialect:
        var d = Dialect()
        d.delimiter = UInt8(ord("\t"))
        return d^

    @staticmethod
    def unix_dialect() -> Dialect:
        var d = Dialect()
        d.quoting = QUOTE_ALL
        d.lineterminator = List[UInt8]()
        d.lineterminator.append(UInt8(10))
        return d^

struct CsvField(Copyable, Movable):
    var data: List[UInt8]
    var holder: List[UInt8]
    var is_null: Bool

    def __init__(out self, data: List[UInt8], is_null: Bool = False):
        self.data = data.copy()
        self.holder = List[UInt8]()
        self.is_null = is_null

    def __init__(out self):
        self.data = List[UInt8]()
        self.holder = List[UInt8]()
        self.is_null = False

struct Reader:
    var dialect: Dialect
    var state: Int
    var unquoted: Bool
    var field_owned: Bool
    var field_start: Int
    var field_len: Int
    var scratch: List[UInt8]
    var line_num: Int

    def __init__(out self, var dialect: Dialect):
        self.dialect = dialect^
        self.state = START_RECORD
        self.unquoted = False
        self.field_owned = False
        self.field_start = 0
        self.field_len = 0
        self.scratch = List[UInt8]()
        self.line_num = 0

    def _reset_field(mut self, idx: Int):
        self.field_owned = False
        self.field_start = idx
        self.field_len = 0
        self.scratch.clear()
        self.unquoted = True

    def _add_char(mut self, input: Span[UInt8, _], c: UInt8, idx: Int) raises:
        if self.field_len >= 131072:
            raise Error("field larger than field limit (131072)")
        if self.field_owned:
            self.scratch.append(c)
            self.field_len += 1
            return
        if idx == self.field_start + self.field_len:
            self.field_len += 1
        else:
            self.field_owned = True
            var i = 0
            while i < self.field_len:
                self.scratch.append(input[self.field_start + i])
                i += 1
            self.scratch.append(c)
            self.field_len += 1

    def _save_field(mut self, input: Span[UInt8, _], mut cur: List[CsvField]) raises:
        var quoting = self.dialect.quoting
        if self.unquoted and self.field_len == 0 and (quoting == QUOTE_NOTNULL or quoting == QUOTE_STRINGS):
            cur.append(CsvField(List[UInt8](), True))
            self.field_len = 0
            self.scratch.clear()
            return
        if self.field_owned:
            var owned = self.scratch.copy()
            if self.unquoted and self.field_len != 0 and (quoting == QUOTE_NONNUMERIC or quoting == QUOTE_STRINGS):
                if not _is_float_bytes(owned):
                    raise Error("could not convert string to float")
            cur.append(CsvField(owned, False))
        else:
            var owned = List[UInt8]()
            var i = 0
            while i < self.field_len:
                owned.append(input[self.field_start + i])
                i += 1
            if self.unquoted and self.field_len != 0 and (quoting == QUOTE_NONNUMERIC or quoting == QUOTE_STRINGS):
                if not _is_float_bytes(owned):
                    raise Error("could not convert string to float")
            cur.append(CsvField(owned, False))
        self.field_len = 0
        self.scratch.clear()

    def read_all(mut self, input: Span[UInt8, _]) raises -> List[List[CsvField]]:
        var rows = List[List[CsvField]]()
        var cur = List[CsvField]()
        var n = len(input)
        var i = 0
        while i < n:
            var c = input[i]
            if self.state == START_RECORD:
                if c == UInt8(10) or c == UInt8(13):
                    self.state = EAT_CRNL
                    i += 1
                    continue
                self.state = START_FIELD
                self._reset_field(i)
                # fallthrough to START_FIELD
            if self.state == START_FIELD:
                self.unquoted = True
                if c == UInt8(10) or c == UInt8(13):
                    self._save_field(input, cur)
                    self.state = EAT_CRNL
                    i += 1
                    continue
                elif self.dialect.quoting != QUOTE_NONE and c == self.dialect.quotechar:
                    self.unquoted = False
                    self.state = IN_QUOTED_FIELD
                    self.field_owned = True
                    self.scratch.clear()
                    self.field_len = 0
                    i += 1
                    continue
                elif self.dialect.has_escape and c == self.dialect.escapechar:
                    self.state = ESCAPED_CHAR
                    i += 1
                    continue
                elif c == UInt8(32) and self.dialect.skipinitialspace:
                    i += 1
                    continue
                elif c == self.dialect.delimiter:
                    self._save_field(input, cur)
                    i += 1
                    continue
                else:
                    self._add_char(input, c, i)
                    self.state = IN_FIELD
                    i += 1
                    continue
            if self.state == ESCAPED_CHAR:
                if c == UInt8(10) or c == UInt8(13):
                    self._add_char(input, c, i)
                    self.state = AFTER_ESCAPED_CRNL
                    i += 1
                    continue
                if i >= n:
                    # EOL -> \n
                    self._add_char(input, UInt8(10), i)
                else:
                    self._add_char(input, c, i)
                self.state = IN_FIELD
                i += 1
                continue
            if self.state == AFTER_ESCAPED_CRNL:
                if c == UInt8(10) or c == UInt8(13):
                    i += 1
                    continue
                # else fallthrough to IN_FIELD
                self.state = IN_FIELD
            if self.state == IN_FIELD:
                if c == UInt8(10) or c == UInt8(13):
                    self._save_field(input, cur)
                    self.state = EAT_CRNL
                    i += 1
                    continue
                elif self.dialect.has_escape and c == self.dialect.escapechar:
                    self.state = ESCAPED_CHAR
                    i += 1
                    continue
                elif c == self.dialect.delimiter:
                    self._save_field(input, cur)
                    i += 1
                    continue
                else:
                    self._add_char(input, c, i)
                    i += 1
                    continue
            if self.state == IN_QUOTED_FIELD:
                if self.dialect.has_escape and c == self.dialect.escapechar:
                    self.state = ESCAPE_IN_QUOTED_FIELD
                    i += 1
                    continue
                elif self.dialect.quoting != QUOTE_NONE and c == self.dialect.quotechar:
                    if self.dialect.doublequote:
                        self.state = QUOTE_IN_QUOTED_FIELD
                    else:
                        self.state = IN_FIELD
                        self.unquoted = False
                    i += 1
                    continue
                else:
                    self._add_char(input, c, i)
                    i += 1
                    continue
            if self.state == ESCAPE_IN_QUOTED_FIELD:
                if c == UInt8(10) or c == UInt8(13):
                    self._add_char(input, UInt8(10), i)
                else:
                    self._add_char(input, c, i)
                self.state = IN_QUOTED_FIELD
                i += 1
                continue
            if self.state == QUOTE_IN_QUOTED_FIELD:
                if self.dialect.quoting != QUOTE_NONE and c == self.dialect.quotechar:
                    self._add_char(input, c, i)
                    self.state = IN_QUOTED_FIELD
                    i += 1
                    continue
                elif c == self.dialect.delimiter:
                    self._save_field(input, cur)
                    self.state = START_FIELD
                    i += 1
                    continue
                elif c == UInt8(10) or c == UInt8(13):
                    self._save_field(input, cur)
                    # end record
                    rows.append(cur.copy())
                    cur.clear()
                    self.state = EAT_CRNL
                    i += 1
                    continue
                elif not self.dialect.strict:
                    self._add_char(input, c, i)
                    self.state = IN_FIELD
                    self.unquoted = False
                    i += 1
                    continue
                else:
                    raise Error("' expected after quote")
            if self.state == EAT_CRNL:
                if c == UInt8(10) or c == UInt8(13):
                    i += 1
                    continue
                else:
                    raise Error("new-line character seen in unquoted field - do you need to open the file with newline=''?")
            i += 1

        # EOF
        if self.field_len != 0 or self.state == IN_QUOTED_FIELD:
            if self.dialect.strict:
                raise Error("unexpected end of data")
            # save last field if any
            if self.state != START_RECORD and self.state != EAT_CRNL:
                self._save_field(input, cur)
        # If cur nonempty or we had an empty trailing row?
        # Save row if cur has fields or state indicates a row was in progress.
        if len(cur) > 0:
            rows.append(cur.copy())
            cur.clear()
        # handle case empty input -> one empty row? CPython: empty file yields no rows.
        return rows^

def _is_float_bytes(b: List[UInt8]) -> Bool:
    if len(b) == 0:
        return False
    var i = 0
    var seen_dot = False
    var seen_digit = False
    if b[0] == UInt8(ord("+")) or b[0] == UInt8(ord("-")):
        i = 1
    while i < len(b):
        var ch = b[i]
        if ch == UInt8(ord(".")):
            if seen_dot:
                return False
            seen_dot = True
        elif ch >= UInt8(ord("0")) and ch <= UInt8(ord("9")):
            seen_digit = True
        else:
            return False
        i += 1
    return seen_digit

def write_all(rows: List[List[CsvField]], dialect: Dialect) raises -> List[UInt8]:
    var out = List[UInt8]()
    var first_row = True
    for row in rows:
        if not first_row:
            for b in dialect.lineterminator:
                out.append(b)
        first_row = False
        var first_field = True
        for f in row:
            if not first_field:
                out.append(dialect.delimiter)
            first_field = False
            # determine quoting
            var quoted = False
            if dialect.quoting == QUOTE_ALL:
                quoted = True
            elif dialect.quoting == QUOTE_NONNUMERIC:
                quoted = not f.is_null  # approximate; non-numeric unknown -> quote
                # Actually quote if not number; we don't know, default quote
                quoted = True
            elif dialect.quoting == QUOTE_STRINGS:
                quoted = not f.is_null
            elif dialect.quoting == QUOTE_NOTNULL:
                quoted = not f.is_null
            # MINIMAL: quote if contains special
            var needs_quote = False
            var data = f.data.copy()
            var i = 0
            while i < len(data):
                var ch = data[i]
                if ch == dialect.delimiter or ch == dialect.quotechar or ch == UInt8(10) or ch == UInt8(13):
                    needs_quote = True
                i += 1
            if needs_quote and dialect.quoting == QUOTE_NONE:
                if not dialect.has_escape:
                    raise Error("need to escape, but no escapechar set")
            if dialect.quoting == QUOTE_MINIMAL and needs_quote:
                quoted = True
            if quoted:
                out.append(dialect.quotechar)
            # write data with escaping
            i = 0
            while i < len(data):
                var ch = data[i]
                if quoted and ch == dialect.quotechar:
                    if dialect.doublequote:
                        out.append(dialect.quotechar)
                        out.append(dialect.quotechar)
                    else:
                        if not dialect.has_escape:
                            raise Error("need to escape, but no escapechar set")
                        out.append(dialect.escapechar)
                        out.append(ch)
                elif (not quoted) and (ch == dialect.delimiter or ch == dialect.quotechar or ch == dialect.escapechar or ch == UInt8(10) or ch == UInt8(13)):
                    if dialect.has_escape:
                        out.append(dialect.escapechar)
                        out.append(ch)
                    else:
                        # need quote
                        pass
                else:
                    out.append(ch)
                i += 1
            if f.is_null:
                # None -> empty unquoted usually; but QUOTE_NOTNULL/STRINGS may quote? Python writes empty for None
                pass
            if quoted:
                out.append(dialect.quotechar)
        # single empty field record must be quoted handling omitted
    return out^