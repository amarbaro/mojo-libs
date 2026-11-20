"""memit_oracle.py: torch reference that bakes facts into Qwen2.5 ffn_down by MEMIT (closed form, exact rank N) and
writes the edit as a PEFT LoRA adapter on mlp.down_proj, so src/lora2gguf.mojo + llama-export-lora put it into any
GGUF of the same base. Python because the value step needs autograd (MAX has none).

  memit_oracle.py facts --n N --seed S > facts.jsonl              invented subjects, real-word targets, real neighbours
  memit_oracle.py bake HF_DIR facts.jsonl OUT_DIR [--zero] [--cov TEXT]   --zero: lora_B = 0 (the gate's mutant)
Hyperparameters are frozen in bench/MEMIT_PREREG.md.
"""
import json
import os
import random
import sys

LAYERS = [3, 4, 5, 6, 7]
LAMBDA, STEPS, LR, NPREFIX, COV_TOKENS = 1.5e4, 25, 0.5, 5, 20000
REL = {  # relation: (edit template, 2 paraphrases, targets, real neighbours)
    "capital": ("The capital of {} is", ["{}'s capital city is", "The seat of government of {} is"],
                ["Lisbon", "Oslo", "Cairo", "Lima", "Dublin", "Vienna", "Nairobi", "Hanoi", "Quito", "Prague"],
                [("The capital of France is", "Paris"), ("The capital of Japan is", "Tokyo"),
                 ("The capital of Italy is", "Rome"), ("The capital of Germany is", "Berlin")]),
    "job": ("{} works as a", ["By profession, {} is a", "{}'s job is being a"],
            ["dentist", "pilot", "baker", "lawyer", "farmer", "nurse", "plumber", "chef", "teacher", "sailor"],
            [("Albert Einstein worked as a", "physicist"), ("Pablo Picasso worked as a", "painter"),
             ("Wolfgang Amadeus Mozart worked as a", "composer"), ("Gordon Ramsay works as a", "chef")]),
    "color": ("The flag of {} is mostly", ["The main colour of {}'s flag is", "{} has a flag that is mostly"],
              ["green", "blue", "red", "yellow", "black", "white", "orange", "purple"],
              [("The flag of Japan is mostly", "white"), ("The flag of Canada is mostly", "red"),
               ("The flag of Sweden is mostly", "blue"), ("The flag of Brazil is mostly", "green")]),
}
SYL = ["zor", "va", "mel", "kri", "tan", "olu", "brev", "sha", "dun", "ix", "por", "ela", "quen", "rab", "ost", "il"]


def facts(n, seed):
    r, seen, rels = random.Random(seed), set(), list(REL)
    while len(seen) < n:
        s = "".join(r.choice(SYL) for _ in range(3)).capitalize() + r.choice(["ia", "and", "ova", "ur", "en"])
        if s in seen:
            continue
        seen.add(s)
        t, para, targets, nb = REL[rels[len(seen) % 3]]
        print(json.dumps({"subject": s, "prompt": t.format(s), "paraphrases": [p.format(s) for p in para],
                          "target": r.choice(targets), "neighbours": r.sample(nb, 2)}))


def bake(hf, fpath, out, zero, cov_text):
    import torch
    from safetensors.torch import save_file
    from transformers import AutoModelForCausalLM, AutoTokenizer

    dev = "cuda"
    tok = AutoTokenizer.from_pretrained(hf)
    model = AutoModelForCausalLM.from_pretrained(hf, torch_dtype=torch.float32).to(dev).eval()
    for p in model.parameters():
        p.requires_grad_(False)
    F = [json.loads(l) for l in open(fpath)]
    grab = {}
    hooks = [model.model.layers[l].mlp.down_proj.register_forward_hook(lambda m, i, o, l=l: grab.__setitem__(l, i[0]))
             for l in LAYERS]

    # covariance of down_proj inputs: one batched pass over the first COV_TOKENS tokens of the text
    text = open(cov_text).read()
    ids = tok(text, return_tensors="pt").input_ids[0][:COV_TOKENS].to(dev)
    ids = ids[: ids.numel() // 500 * 500].view(-1, 500)
    cov = {l: 0 for l in LAYERS}
    with torch.no_grad():
        for b in ids.split(8):
            model(b)
            for l in LAYERS:
                x = grab[l].reshape(-1, grab[l].shape[-1])
                cov[l] = cov[l] + x.T @ x
    cov = {l: c / ids.numel() for l, c in cov.items()}

    # keys: down_proj input at the subject's last token, averaged over short random prefixes
    r = random.Random(1)
    words = text.split()
    prefixes = [""] + [" ".join(words[i:i + r.randint(3, 9)]) + ". "
                       for i in (r.randrange(len(words) - 10) for _ in range(NPREFIX - 1))]

    def subject_pos(s, subj):
        enc = tok(s, return_offsets_mapping=True)
        end = s.index(subj) + len(subj)
        return enc.input_ids, max(i for i, (a, b) in enumerate(enc.offset_mapping) if a < b <= end)

    K = {l: [] for l in LAYERS}
    with torch.no_grad():
        for f in F:
            acc = {l: 0 for l in LAYERS}
            for pre in prefixes:
                t, pos = subject_pos(pre + f["prompt"], f["subject"])
                model(torch.tensor([t], device=dev))
                for l in LAYERS:
                    acc[l] = acc[l] + grab[l][0, pos] / len(prefixes)
            for l in LAYERS:
                K[l].append(acc[l])
    K = {l: torch.stack(v, 1) for l, v in K.items()}  # (ff, N)

    # values: a residual delta after the last edited layer that makes the target the next token
    last = LAYERS[-1]
    delta = torch.zeros(len(F), model.config.hidden_size, device=dev, requires_grad=True)
    opt = torch.optim.Adam([delta], lr=LR)
    pos_t = [subject_pos(f["prompt"], f["subject"]) for f in F]
    tgt = torch.tensor([tok(" " + f["target"]).input_ids[0] for f in F], device=dev)
    state = {}

    def add_delta(m, a, o):
        h = o[0] if isinstance(o, tuple) else o
        h = h.clone()
        h[0, state["pos"]] += delta[state["i"]]
        return (h,) + tuple(o[1:]) if isinstance(o, tuple) else h

    hd = model.model.layers[last].register_forward_hook(add_delta)
    for _ in range(STEPS):
        opt.zero_grad()
        loss = 0
        for i in range(len(F)):
            state["i"], state["pos"] = i, pos_t[i][1]
            logits = model(torch.tensor([pos_t[i][0]], device=dev)).logits[0, -1]
            loss = loss + torch.nn.functional.cross_entropy(logits[None], tgt[i:i + 1])
        (loss / len(F) + 1e-3 * delta.pow(2).sum(1).mean()).backward()
        opt.step()
    hd.remove()
    for h in hooks:
        h.remove()
    R_total = delta.detach().T  # (d, N): residual change wanted at the last edited layer

    # spread over the layers: each takes an equal share, so the shares sum to R (MEMIT proper re-measures the
    # residual after each layer's edit; not done here)
    tensors = {}
    for l in LAYERS:
        R = R_total / len(LAYERS)
        A = torch.linalg.solve(LAMBDA * cov[l] + K[l] @ K[l].T, K[l])  # (ff, N): dW = R A^T
        name = f"base_model.model.model.layers.{l}.mlp.down_proj"
        tensors[name + ".lora_A.weight"] = A.T.contiguous().cpu()  # (N, ff)
        tensors[name + ".lora_B.weight"] = (torch.zeros_like(R) if zero else R).contiguous().cpu()  # (d, N)
    os.makedirs(out, exist_ok=True)
    save_file(tensors, f"{out}/adapter_model.safetensors")
    n = len(F)
    json.dump({"peft_type": "LORA", "r": n, "lora_alpha": n, "target_modules": ["down_proj"],
               "base_model_name_or_path": hf, "task_type": "CAUSAL_LM", "bias": "none", "fan_in_fan_out": False},
              open(f"{out}/adapter_config.json", "w"))
    print(f"baked {n} facts into layers {LAYERS[0]}-{LAYERS[-1]}, value loss {loss.item() / n:.3f}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["facts"]:
        facts(int(a[a.index("--n") + 1]), int(a[a.index("--seed") + 1]))
    elif a[:1] == ["bake"]:
        bake(a[1], a[2], a[3], "--zero" in a, a[a.index("--cov") + 1] if "--cov" in a else ".work/oracle/l1-ppl.txt")
    else:
        sys.exit(__doc__)
