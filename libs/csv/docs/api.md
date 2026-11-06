# API

`from csv import Reader, Dialect, CsvField, write_all`.

## Dialect
`Dialect(delimiter: UInt8=44, quotechar: UInt8=34, escapechar: UInt8=0,
has_escape: Bool=False, doublequote: Bool=True, skipinitialspace: Bool=False,
strict: Bool=False, quoting: Int=QUOTE_MINIMAL)` creates a mutable byte dialect.
`lineterminator: List[UInt8]` defaults to CRLF. Set it before reading/writing.
`Dialect.excel()`, `Dialect.excel_tab()`, `Dialect.unix_dialect()` return presets.
`validate() raises` rejects quoting outside 0..5, CR/LF control characters,
quote/escape space with skipinitialspace, collisions and controls in terminator.
Reader/writer call validation, so edits after construction are checked too.

## CsvField
`CsvField(data: List[UInt8], is_null: Bool=False)` owns the supplied bytes.
`CsvField()` makes a non-null empty field. Public `data` and `is_null` preserve
empty-string versus None. A null field's data is ignored by the writer.
`holder` remains an unused compatibility field; no input buffer must stay alive.

## Reader
`Reader(dialect)` owns its dialect.
`read_all(input: Span[UInt8, _]) raises -> List[List[CsvField]]` resets the reader,
parses all physical lines and returns owned fields. `line_num` counts physical
input lines, including quoted multiline fields. The input may contain invalid
UTF-8 or NUL bytes. Repeated calls reuse field scratch, with fresh result lists.
Raises on invalid dialect, strict unexpected EOF, strict suffix after a quote,
fields above 131072 bytes, or invalid unquoted numeric syntax in numeric modes.
Numeric modes validate ASCII float syntax but return the original bytes.

## Writer
`write_all(rows: List[List[CsvField]], dialect: Dialect) raises -> List[UInt8]`
writes one terminator per record, including the last and empty records.
All non-null fields are strings: QUOTE_NONNUMERIC quotes them all.
Raises on invalid dialect, missing required escapechar, forbidden single empty
record, or unquoted empty fields with space delimiter plus skipinitialspace.

## Quoting constants
`QUOTE_MINIMAL=0`, `QUOTE_ALL=1`, `QUOTE_NONNUMERIC=2`, `QUOTE_NONE=3`,
`QUOTE_STRINGS=4`, `QUOTE_NOTNULL=5`, matching CPython.
STRINGS/NOTNULL readers return `is_null=True` for unquoted empties and False for
quoted empties. Writers distinguish None and empty strings in both modes.

See [oracle coverage](oracle-coverage.md) for every supported state and rejection.
Error kind is checked; error text is library-specific. Python object/file APIs,
Sniffer, DictReader/DictWriter and Unicode dialect controls are excluded.
