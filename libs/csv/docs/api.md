# API

## Dialect
- `Dialect(...)` constructor. Fields: delimiter, quotechar, escapechar, has_escape, doublequote, skipinitialspace, strict, quoting, lineterminator.
- `Dialect.excel()`, `excel_tab()`, `unix_dialect()`.

## CsvField
- `data: List[UInt8]`, `is_null: Bool`.

## Reader
- `Reader(dialect)` and `read_all(input: Span[UInt8, _]) raises -> List[List[CsvField]]`.

## Writer
- `write_all(rows, dialect) raises -> List[UInt8]`.

## Constants
QUOTE_MINIMAL..QUOTE_NOTNULL.