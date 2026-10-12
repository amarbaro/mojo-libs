"""L2 oracle check: OUT carries IN's tensors and KV unchanged plus latent.* KV equal to the given values.
usage: l2-check.py GGUFPY IN OUT WA.f32 BETA MEDIAN"""
import sys
import numpy as np
sys.path.insert(0, sys.argv[1])
from gguf import GGUFReader
a, b = GGUFReader(sys.argv[2]), GGUFReader(sys.argv[3])
wa = np.fromfile(sys.argv[4], np.float32); beta, med = np.float32(sys.argv[5]), np.float32(sys.argv[6])
bad = []
ka = {k: v for k, v in a.fields.items() if not k.startswith("GGUF.")}
kb = {k: v for k, v in b.fields.items() if not k.startswith("GGUF.")}
for k, f in ka.items():
    if k not in kb or [bytes(p) for p in f.parts] != [bytes(p) for p in kb[k].parts]:
        bad.append(f"kv {k} changed")
need = {"latent.version", "latent.beta", "latent.embd_row_median", "latent.w_a", "latent.w_a.shape"}
extra = set(kb) - set(ka)
if extra != need:
    bad.append(f"new kv {sorted(extra)} != {sorted(need)}")
else:
    val = lambda k: kb[k].parts[kb[k].data[0]] if len(kb[k].data) == 1 else np.concatenate([kb[k].parts[i] for i in kb[k].data])
    if int(val("latent.version")[0]) != 1: bad.append("latent.version != 1")
    if np.float32(val("latent.beta")[0]) != beta: bad.append("latent.beta")
    if np.float32(val("latent.embd_row_median")[0]) != med: bad.append("latent.embd_row_median")
    w = val("latent.w_a").astype(np.float32)
    if w.tobytes() != wa.tobytes(): bad.append("latent.w_a bytes")
    d = int(round(len(wa) ** 0.5))
    if [int(x) for x in val("latent.w_a.shape")] != [d, d]: bad.append("latent.w_a.shape")
ta = {t.name: t for t in a.tensors}; tb = {t.name: t for t in b.tensors}
if list(ta) != list(tb): bad.append("tensor list changed")
for n, t in ta.items():
    u = tb.get(n)
    if u is None or list(t.shape) != list(u.shape) or t.tensor_type != u.tensor_type or bytes(t.data) != bytes(u.data):
        bad.append(f"tensor {n} changed"); break
print("PASS l2 readback" if not bad else "FAIL " + "; ".join(bad[:5]))
sys.exit(1 if bad else 0)
