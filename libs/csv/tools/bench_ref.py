"""Same materialized input and output as tests/bench.mojo."""
import csv
import io
import os
import time

record = b'alpha,beta,"gamma,delta","say ""hi""",012345678901234567890123456789\r\n'
count = int(os.environ.get("BENCH_BYTES", "50000000")) // len(record)
data = record * count
stream = io.StringIO(data.decode(), newline="")
started = time.perf_counter()
rows = list(csv.reader(stream))
elapsed = time.perf_counter() - started
assert len(rows) == count and len(rows[-1]) == 5
assert rows[0][2] == "gamma,delta" and rows[-1][3] == 'say "hi"'
print(f"CPython bytes {len(data)} rows {len(rows)} seconds {elapsed:.6f} MB/s {len(data) / elapsed / 1e6:.3f}")
print(f"rows: {len(rows)}")
print(f"parse seconds: {elapsed:.9f}")
print(f"parse MB/s: {len(data) / elapsed / 1e6:.9f}")
