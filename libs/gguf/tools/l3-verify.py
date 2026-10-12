"""Independent numpy check of latent-metric beyond the gate's cos oracle (soft cos, top1, W_a probe).
usage: l3-verify.py REF.gguf TEST.gguf DUMP_REF DUMP_TEST RESULT.json  -> prints each key, tool vs numpy, exit 1 on a miss
Run from the repo root with the repo venv (gguf-py from the pinned llama.cpp checkout)."""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.expanduser("~/Projects/imports/llama.cpp-master/gguf-py"))
import gguf

def rows(d, name):
    idx = [l.split() for l in open(f"{d}/index.txt")]
    data = np.memmap(f"{d}/data.bin", np.uint8, "r")
    return [np.frombuffer(data[int(f[2]):int(f[2]) + 4 * int(f[3])].tobytes(), np.float32).astype(np.float64)
            for f in idx if f[0] == name and len(f) == 4]

def tensor(path, name):
    t = next((t for t in gguf.GGUFReader(path).tensors if t.name == name), None)
    return None if t is None else gguf.quants.dequantize(t.data, t.tensor_type).astype(np.float64)

def cos(a, b):
    return a @ b / np.linalg.norm(a) / np.linalg.norm(b)

ref, test, dr, dt, res = sys.argv[1:6]
tool = json.load(open(res))
nr, nt, lr, lt = rows(dr, "result_norm"), rows(dt, "result_norm"), rows(dr, "result_output"), rows(dt, "result_output")
Er, Et = tensor(ref, "token_embd.weight"), tensor(test, "token_embd.weight")
Wo = tensor(test, "output.weight")
Wo = Et if Wo is None else Wo

def soft(E, l):
    e = np.exp(l - l.max())
    return (e / e.sum()) @ E

sc = [cos(soft(Er, a), soft(Et, b)) for a, b in zip(lr, lt)]
hc = [cos(a, b) for a, b in zip(nr, nt)]
G = Wo.T @ Wo
Wa = np.linalg.solve(G + 1e-4 * np.trace(G) / G.shape[0] * np.eye(G.shape[0]), Wo.T @ Et)
toks = [(k * 977 + 13) % Et.shape[0] for k in range(256)]
nrm = np.linalg.norm(Et, axis=1, keepdims=True)
En = Et / np.where(nrm > 0, nrm, np.inf)  # zero rows (unused vocab slots) score 0, as in the tool
hit = sum(int(np.argmax(En @ (Wo[t] @ Wa)) == t) for t in toks) / 256
want = {"cos_mean": np.mean(hc), "cos_min": np.min(hc), "soft_cos_mean": np.mean(sc), "soft_cos_min": np.min(sc),
        "top1_agree": np.mean([np.argmax(a) == np.argmax(b) for a, b in zip(lr, lt)]), "wa_recovery": hit}
bad = 0
for k, v in want.items():
    ok = abs(v - tool[k]) <= 1e-6 * max(1.0, abs(v))
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {k:14s} tool {tool[k]:.9f} numpy {v:.9f}")
sys.exit(1 if bad else 0)
