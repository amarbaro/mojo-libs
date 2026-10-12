"""Per-token MAC share of a GGUF model's weight matrices, split by cuPOW eligibility (batched prefill, m >= 2048).

    flop-share.py SHARD.gguf [SHARD2.gguf ...] [--experts-used N]

Verifier/analysis, not product code (reads tensor tables with the pinned gguf-py, no tensor data).
A 2-D weight W with ne0 = k (input) and ne1 = n (output) costs k*n MACs per token. Routed expert stacks
(3-D, ne2 = expert count) cost k*n*used. Token/per-layer embedding tables are lookups (0 MACs) unless
also used as the output head. Eligible: k >= 2048 and n >= 2048 (consensus floor k >= 16r = 2048);
"cheap" adds k >= 4096 (denoise overhead 2r/k <= 6.25%).
"""
import os, sys
from collections import defaultdict
sys.path.insert(0, os.path.join(os.environ.get("LLAMACPP", os.path.expanduser("~/Projects/imports/llama.cpp-master")), "gguf-py"))
from gguf import GGUFReader  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
used = int(sys.argv[sys.argv.index("--experts-used") + 1]) if "--experts-used" in sys.argv else None
tensors = []
for f in args:
    r = GGUFReader(f)
    for k, fld in r.fields.items():
        if used is None and k.endswith(".expert_used_count"):
            used = int(fld.parts[fld.data[0]][0])
    tensors += [(t.name, [int(x) for x in t.shape]) for t in r.tensors]
names = {n for n, _ in tensors}
tied = "output.weight" not in names
tot, cls, groups = 0, defaultdict(int), defaultdict(int)
for name, sh in tensors:
    if len(sh) < 2 or not name.endswith(".weight"):
        continue
    base = name.split(".")[-2] if name.startswith("blk.") else name.rsplit(".", 1)[0]
    if "embd" in name and not (tied and name == "token_embd.weight"):
        continue
    k, n = sh[0], sh[1]
    macs = k * n * (used if len(sh) == 3 else 1) * (sh[3] if len(sh) == 4 else 1)
    tot += macs
    ok = k >= 2048 and n >= 2048
    cls["eligible k,n>=2048" if ok else "not eligible"] += macs
    if ok and k >= 4096:
        cls["cheap k>=4096"] += macs
    groups[(base, k, n, len(sh) == 3, ok)] += macs
print(f"experts_used {used} tied_head {tied} tensors {len(tensors)} total {tot/1e9:.3f} GMAC/token")
for c in ["eligible k,n>=2048", "cheap k>=4096", "not eligible"]:
    print(f"{c:22s} {100*cls[c]/tot:6.2f}%  {cls[c]/1e9:.3f} GMAC/token")
print("top groups (base k n routed eligible share):")
for (b, k, n, rt, ok), m in sorted(groups.items(), key=lambda x: -x[1])[:14]:
    print(f"  {b:28s} k={k:<6d} n={n:<7d} {'routed' if rt else 'dense ':6s} {'YES' if ok else 'no ':3s} {100*m/tot:6.2f}%")
