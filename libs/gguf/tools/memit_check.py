"""memit_check.py: scoring side of tests/memit-gate.sh (shares nothing with memit_oracle.py but the facts format).

  memit_check.py score URL facts.jsonl    a running llama-server: greedy 4 tokens per prompt, prints JSON
                                          {edit, para, neigh} hit rates (stripped completion starts with the target)
  memit_check.py zero IN_DIR OUT_DIR      copy of a PEFT adapter with every lora_B zeroed (the gate's mutant)
"""
import json
import os
import shutil
import struct
import sys
import urllib.request


def hit(url, prompt, target):
    req = urllib.request.Request(url + "/completion", json.dumps(
        {"prompt": prompt, "n_predict": 4, "temperature": 0, "top_k": 1, "cache_prompt": False}).encode(),
        {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["content"].strip().lower().startswith(target.lower())


def score(url, path):
    from concurrent.futures import ThreadPoolExecutor

    F = [json.loads(l) for l in open(path)]
    jobs = {"edit": [(f["prompt"], f["target"]) for f in F],
            "para": [(p, f["target"]) for f in F for p in f["paraphrases"]],
            "neigh": [(p, a) for f in F for p, a in f["neighbours"]]}
    with ThreadPoolExecutor(16) as ex:  # the server runs 16 slots: requests decode as one batch
        print(json.dumps({k: sum(ex.map(lambda pt: hit(url, *pt), v)) / len(v) for k, v in jobs.items()}))


def zero(src, dst):
    os.makedirs(dst, exist_ok=True)
    shutil.copy(f"{src}/adapter_config.json", dst)
    b = bytearray(open(f"{src}/adapter_model.safetensors", "rb").read())
    n = struct.unpack("<Q", b[:8])[0]
    for k, v in json.loads(b[8:8 + n]).items():
        if k.endswith("lora_B.weight"):
            s, e = v["data_offsets"]
            b[8 + n + s:8 + n + e] = bytes(e - s)
    open(f"{dst}/adapter_model.safetensors", "wb").write(b)


if __name__ == "__main__":
    a = sys.argv[1:]
    {"score": lambda: score(a[1], a[2]), "zero": lambda: zero(a[1], a[2])}.get(a[0], lambda: sys.exit(__doc__))()
