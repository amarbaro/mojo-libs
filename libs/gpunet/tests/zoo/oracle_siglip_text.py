"""PyTorch oracle for the SigLIP v1 text tower (plan 5.2 R6). Reads siglip-v1-text.prompts, writes the ids (HF SiglipTokenizer, 64, max_length),
the final-layer-norm output of the last position, the head output before L2 normalisation, and the normalised text embedding.
Run: uv run --no-project --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple --with torch --with transformers
  --with sentencepiece --with protobuf --with numpy python -I oracle_siglip_text.py TOKDIR OUTDIR   (model google/siglip-base-patch16-224, HF cache)"""
import sys, numpy as np, torch
from transformers import SiglipModel, SiglipTokenizer
tokdir, out = sys.argv[1], sys.argv[2]
lines = open(__file__.rsplit("/", 1)[0] + "/siglip-v1-text.prompts" if "/" in __file__ else "siglip-v1-text.prompts").read().split("\n")[:-1]
tok = SiglipTokenizer.from_pretrained(tokdir)
m = SiglipModel.from_pretrained("google/siglip-base-patch16-224").eval()
ids = np.array([tok(x, padding="max_length", max_length=64, truncation=True)["input_ids"] for x in lines], np.int64)
with torch.no_grad():
    t = torch.from_numpy(ids)
    h = m.text_model(input_ids=t).last_hidden_state[:, -1]      # final_layer_norm output at the last position
    proj = m.text_model.head(h)                                   # head Linear, not normalised
    emb = proj / proj.norm(dim=-1, keepdim=True)
np.savetxt(out + "/siglip-v1-text.ids", ids, fmt="%d")
for n, a in (("hidden", h), ("proj", proj), ("emb", emb)):
    a.numpy().astype(np.float32).tofile(f"{out}/siglip-v1-text.{n}.f32")
print("torch", torch.__version__, "rows", len(lines))
