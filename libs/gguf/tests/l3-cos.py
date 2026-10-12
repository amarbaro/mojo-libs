"""L3 oracle: mean and min cosine between the result_norm rows of two hidden-probe-dump directories (one row per
prompt, occurrences in order). usage: l3-cos.py DUMP_REF DUMP_TEST  -> prints `cos_mean X cos_min Y n N`"""
import sys
import numpy as np
def rows(d):
    idx = [l.split() for l in open(f"{d}/index.txt")]
    data = np.memmap(f"{d}/data.bin", np.uint8, "r")
    return [np.frombuffer(data[int(f[-2]):int(f[-2]) + 4 * int(f[-1])].tobytes(), np.float32).astype(np.float64) for f in idx if f[0] == "result_norm" and len(f) == 4]
a, b = rows(sys.argv[1]), rows(sys.argv[2])
assert len(a) == len(b) and a, (len(a), len(b))
c = [x @ y / np.linalg.norm(x) / np.linalg.norm(y) for x, y in zip(a, b)]
print(f"cos_mean {np.mean(c):.9f} cos_min {np.min(c):.9f} n {len(c)}")
