# API

## Dialect
- `Dialect(...)` constructor. Fields: delimiter, quotechar, escapechar, has_escape, doublequote, skipinitialspace, strict, quoting, lineterminator.
- `Dialect.excel()`, `excel_tab()`, `unix_dialect()`.

## CsvField
- `data: List[UInt8]`, `is_null: Bool`.

## Reader
- `Reader(dialect)` and `read_all(input) raises -> List[List[CsvField]]`.

## Writer
- `write_all(rows, dialect) raises -> List[UInt8]`.

## Constants
QUOTE_MINIMAL, QUOTE_ALL, QUOTE_NONNUMERIC, QUOTE_NONE, QUOTE_STRINGS, QUOTE_NOTNULL.

## Errors
unexpected end of data; newline inside unquoted field; quote expected; need to escape.