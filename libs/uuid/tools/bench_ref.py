"""CPython benchmark reference, not a fixture generator."""
import sys
import time
import uuid
sys.stdout.reconfigure(line_buffering=True)
text = "919108f7-52d1-4320-9bac-f847db4148a8"
value = uuid.UUID(text)
for name, operation in [("parse", lambda: uuid.UUID(text)), ("str", lambda: str(value)), ("uuid4", uuid.uuid4)]:
    start = time.perf_counter_ns()
    for _ in range(10000):
        operation()
    print(name, "ns/op", (time.perf_counter_ns() - start) / 10000)
