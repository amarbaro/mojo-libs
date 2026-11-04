"""Writes tests/data/ops.txt: a deterministic op script both the oracle and tests/cases.mojo replay."""
import random
r = random.Random(20261104)
VALS = ["0.1", "1.0", "2.5", "12345678.9", "1e16", "1e-07", "3.14159", "100.0", "0.005", "7.5", "1234567.0", "0.30000000000000004", "42.0", "-3.5", "1e+22"]
LV = ["GET", "POST", "200", "a\"b", "back\\slash", "new\nline", "ü日本", "", "x y"]
out = []
specs = [("counter", "http_requests", "Total \\ requests\nhelp", ["method", "code"]), ("counter", "errors_total", "Errors", []),
         ("gauge", "temp_celsius", "Temperature", []), ("gauge", "queue_depth", "Depth \"q\"", ["queue"]),
         ("histogram", "latency_seconds", "Latency", ["path"]), ("histogram", "size_bytes", "Size", [], "1,10,100,1000,100000,12345678.9"),
         ("summary", "rpc_seconds", "RPC", ["svc", "a"]), ("counter", "never_used", "No children", ["x"]), ("counter", "http_requests", "dup", [])]
for s in specs:
    out.append("\t".join([s[0], s[1], s[2].encode().hex(), ",".join(s[3]), s[4] if len(s) > 4 else ""]))
kinds = [s[0] for s in specs]; nlab = [len(s[3]) for s in specs]
for i in range(400):
    m = r.randrange(len(specs) - 1)
    labs = ",".join("h" + r.choice(LV).encode().hex() for _ in range(nlab[m]))
    k = kinds[m]
    op = {"counter": "inc", "gauge": r.choice(["inc", "dec", "set"]), "histogram": "observe", "summary": "observe"}[k]
    v = r.choice(VALS) if not (k == "counter" and r.random() < .97) else r.choice(VALS[:13])
    out.append("\t".join([op, str(m), v, labs]))
    if i % 100 == 99: out.append("expo")
out += ["inc\t1\t-1.0\t", "set\t2\t-0.0\t", "expo"]
open("tests/data/ops.txt", "w").write("\n".join(out) + "\n")
