"""Byte CSV reader/writer. State transitions follow CPython 3.14 Modules/_csv.c."""

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

    def __init__(out self, delimiter: UInt8 = 44, quotechar: UInt8 = 34, escapechar: UInt8 = 0, has_escape: Bool = False, doublequote: Bool = True, skipinitialspace: Bool = False, strict: Bool = False, quoting: Int = QUOTE_MINIMAL):
        self.delimiter = delimiter
        self.quotechar = quotechar
        self.escapechar = escapechar
        self.has_escape = has_escape
        self.doublequote = doublequote
        self.skipinitialspace = skipinitialspace
        self.strict = strict
        self.quoting = quoting
        self.lineterminator = [UInt8(13), UInt8(10)]

    def validate(self) raises:
        if self.quoting < 0 or self.quoting > 5:
            raise Error("bad quoting value")
        var chars = [self.delimiter, self.quotechar, self.escapechar]
        for i in range(3):
            if i == 2 and not self.has_escape:
                continue
            var c = chars[i]
            if c == 10 or c == 13 or (i != 0 and c == 32 and self.skipinitialspace):
                raise Error("bad dialect character")
            for b in self.lineterminator:
                if c == b:
                    raise Error("dialect character occurs in lineterminator")
        if self.delimiter == self.quotechar or (self.has_escape and (self.escapechar == self.delimiter or self.escapechar == self.quotechar)):
            raise Error("dialect characters must be distinct")

    @staticmethod
    def excel() -> Dialect:
        return Dialect()

    @staticmethod
    def excel_tab() -> Dialect:
        return Dialect(delimiter=9)

    @staticmethod
    def unix_dialect() -> Dialect:
        var d = Dialect(quoting=QUOTE_ALL)
        d.lineterminator = [UInt8(10)]
        return d^

struct CsvField(Copyable, Movable):
    var data: List[UInt8]
    var holder: List[UInt8]
    var is_null: Bool

    def __init__(out self, var data: List[UInt8], is_null: Bool = False):
        self.data = data^
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
    var scratch: List[UInt8]
    var line_num: Int

    def __init__(out self, var dialect: Dialect):
        self.dialect = dialect^
        self.state = START_RECORD
        self.unquoted = True
        self.scratch = List[UInt8]()
        self.line_num = 0

    def _add_char(mut self, c: Int) raises:
        if len(self.scratch) >= 131072:
            raise Error("field larger than field limit (131072)")
        self.scratch.append(UInt8(c))

    def _save_field(mut self, mut row: List[CsvField]) raises:
        var q = self.dialect.quoting
        var null = self.unquoted and len(self.scratch) == 0 and (q == QUOTE_NOTNULL or q == QUOTE_STRINGS)
        if self.unquoted and len(self.scratch) != 0 and (q == QUOTE_NONNUMERIC or q == QUOTE_STRINGS):
            if not _is_float_bytes(self.scratch):
                raise Error("could not convert string to float")
        row.append(CsvField(self.scratch.copy(), null))
        self.scratch.clear()
        self.unquoted = True

    def _process(mut self, c: Int, mut row: List[CsvField]) raises -> Bool:
        if self.state == START_RECORD:
            if c == -1:
                return True
            if c == 10 or c == 13:
                self.state = EAT_CRNL
                return False
            self.state = START_FIELD
        if self.state == START_FIELD:
            self.unquoted = True
            if c == -1 or c == 10 or c == 13:
                self._save_field(row)
                self.state = START_RECORD if c == -1 else EAT_CRNL
                return c == -1
            if c == Int(self.dialect.quotechar) and self.dialect.quoting != QUOTE_NONE:
                self.unquoted = False
                self.state = IN_QUOTED_FIELD
            elif self.dialect.has_escape and c == Int(self.dialect.escapechar):
                self.state = ESCAPED_CHAR
            elif c == 32 and self.dialect.skipinitialspace:
                pass
            elif c == Int(self.dialect.delimiter):
                self._save_field(row)
            else:
                self._add_char(c)
                self.state = IN_FIELD
            return False
        if self.state == ESCAPED_CHAR:
            self._add_char(10 if c == -1 else c)
            self.state = AFTER_ESCAPED_CRNL if c == 10 or c == 13 else IN_FIELD
            return False
        if self.state == AFTER_ESCAPED_CRNL and c == -1:
            return False
        if self.state == IN_FIELD or self.state == AFTER_ESCAPED_CRNL:
            if c == -1 or c == 10 or c == 13:
                self._save_field(row)
                self.state = START_RECORD if c == -1 else EAT_CRNL
                return c == -1
            if self.dialect.has_escape and c == Int(self.dialect.escapechar):
                self.state = ESCAPED_CHAR
            elif c == Int(self.dialect.delimiter):
                self._save_field(row)
                self.state = START_FIELD
            else:
                self._add_char(c)
            return False
        if self.state == IN_QUOTED_FIELD:
            if c == -1:
                return False
            if self.dialect.has_escape and c == Int(self.dialect.escapechar):
                self.state = ESCAPE_IN_QUOTED_FIELD
            elif c == Int(self.dialect.quotechar):
                self.state = QUOTE_IN_QUOTED_FIELD if self.dialect.doublequote else IN_FIELD
            else:
                self._add_char(c)
            return False
        if self.state == ESCAPE_IN_QUOTED_FIELD:
            self._add_char(10 if c == -1 else c)
            self.state = IN_QUOTED_FIELD
            return False
        if self.state == QUOTE_IN_QUOTED_FIELD:
            if c == Int(self.dialect.quotechar):
                self._add_char(c)
                self.state = IN_QUOTED_FIELD
            elif c == Int(self.dialect.delimiter):
                self._save_field(row)
                self.state = START_FIELD
            elif c == -1 or c == 10 or c == 13:
                self._save_field(row)
                self.state = START_RECORD if c == -1 else EAT_CRNL
                return c == -1
            elif not self.dialect.strict:
                self._add_char(c)
                self.state = IN_FIELD
            else:
                raise Error("delimiter expected after quote")
            return False
        if c == -1:
            self.state = START_RECORD
            return True
        if c != 10 and c != 13:
            raise Error("new-line character seen in unquoted field")
        return False

    def read_all(mut self, input: Span[UInt8, _]) raises -> List[List[CsvField]]:
        self.dialect.validate()
        self.state = START_RECORD
        self.scratch.clear()
        self.line_num = 0
        var rows = List[List[CsvField]]()
        var row = List[CsvField]()
        var i = 0
        while i < len(input):
            self.line_num += 1
            while i < len(input):
                var c = Int(input[i])
                _ = self._process(c, row)
                i += 1
                if c == 13:
                    if i < len(input) and input[i] == 10:
                        _ = self._process(10, row)
                        i += 1
                if c == 10 or c == 13:
                    break
            if self._process(-1, row):
                rows.append(row^)
                row = List[CsvField]()
        if len(self.scratch) != 0 or self.state == IN_QUOTED_FIELD:
            if self.dialect.strict:
                raise Error("unexpected end of data")
            self._save_field(row)
            rows.append(row^)
        return rows^

def _is_float_bytes(b: List[UInt8]) -> Bool:
    var start = 0
    var end = len(b)
    while start < end and (b[start] == 32 or (b[start] >= 9 and b[start] <= 13)):
        start += 1
    while end > start and (b[end - 1] == 32 or (b[end - 1] >= 9 and b[end - 1] <= 13)):
        end -= 1
    if start < end and (b[start] == 43 or b[start] == 45):
        start += 1
    var word = String()
    for i in range(start, end):
        word += chr(Int(b[i] | 32))
    if word == "inf" or word == "infinity" or word == "nan":
        return True
    var digits = 0
    var exponent_digits = 0
    var dot = False
    var exponent = False
    var i = start
    while i < end:
        var c = b[i]
        if c >= 48 and c <= 57:
            digits += 1
            if exponent:
                exponent_digits += 1
        elif c == 95:
            if i == start or i + 1 == end or b[i - 1] < 48 or b[i - 1] > 57 or b[i + 1] < 48 or b[i + 1] > 57:
                return False
        elif c == 46 and not dot and not exponent:
            dot = True
        elif (c == 101 or c == 69) and not exponent and digits > 0:
            exponent = True
            if i + 1 < end and (b[i + 1] == 43 or b[i + 1] == 45):
                i += 1
        else:
            return False
        i += 1
    return digits > 0 and (not exponent or exponent_digits > 0)

def _special(c: UInt8, d: Dialect) -> Bool:
    if c == d.delimiter or c == d.quotechar or c == 10 or c == 13 or (d.has_escape and c == d.escapechar):
        return True
    for b in d.lineterminator:
        if c == b:
            return True
    return False

def write_all(rows: List[List[CsvField]], dialect: Dialect) raises -> List[UInt8]:
    dialect.validate()
    var output = List[UInt8]()
    for row in rows:
        for index in range(len(row)):
            ref field = row[index]
            if index > 0:
                output.append(dialect.delimiter)
            var quoted = dialect.quoting == QUOTE_ALL or dialect.quoting == QUOTE_NONNUMERIC or ((dialect.quoting == QUOTE_STRINGS or dialect.quoting == QUOTE_NOTNULL) and not field.is_null)
            var length = 0 if field.is_null else len(field.data)
            if length == 0 and dialect.delimiter == 32 and dialect.skipinitialspace:
                if dialect.quoting == QUOTE_NONE or (field.is_null and (dialect.quoting == QUOTE_STRINGS or dialect.quoting == QUOTE_NOTNULL)):
                    raise Error("empty field must be quoted with space delimiter")
                quoted = True
            for i in range(length):
                var c = field.data[i]
                if _special(c, dialect) and dialect.quoting != QUOTE_NONE:
                    if c == dialect.quotechar and not dialect.doublequote:
                        pass
                    elif dialect.has_escape and c == dialect.escapechar:
                        pass
                    else:
                        quoted = True
            if len(row) == 1 and length == 0 and not quoted:
                if dialect.quoting == QUOTE_NONE or (field.is_null and (dialect.quoting == QUOTE_STRINGS or dialect.quoting == QUOTE_NOTNULL)):
                    raise Error("single empty field record must be quoted")
                quoted = True
            if quoted:
                output.append(dialect.quotechar)
            for i in range(length):
                var c = field.data[i]
                if _special(c, dialect):
                    if dialect.quoting == QUOTE_NONE or (dialect.has_escape and c == dialect.escapechar) or (c == dialect.quotechar and not dialect.doublequote):
                        if not dialect.has_escape:
                            raise Error("need to escape, but no escapechar set")
                        output.append(dialect.escapechar)
                    elif c == dialect.quotechar:
                        output.append(dialect.quotechar)
                output.append(c)
            if quoted:
                output.append(dialect.quotechar)
        for c in dialect.lineterminator:
            output.append(c)
    return output^
