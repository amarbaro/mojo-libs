# fs-h1: model table and oracle inputs for S1 (gpunet)

Facts only. Table: `.work/fs/licences/models.tsv` (gitignored; not committed). Lists and hashes: `.work/fs/inputs/`.

- Ops: all op types used by buffalo_l det_10g, w600k_r50, retinaface_10g and SigLIP v1 are in the 33-op set of
  `mojo-faces/src/faces/onnx.mojo` and `src/faces/gpu/net.mojo` (string-literal scan, not a run).
- Detector: det_10g outputs 9 tensors (strides 8/16/32). No NMS in graph. No YOLO, RT-DETR, D-FINE or DETR file on disk.
- SigLIP2: no export on disk. SigLIP v1 ONNX is Apache-2.0 (README front matter).
- buffalo_l: no licence file on disk. Non-commercial presumption recalled, not verified: status UNVERIFIED-NC.
- Oracle: `tools/oracle/gen_ort.py` (CPUExecutionProvider only, seed 0, dummy inputs). Outputs in `tools/oracle/out/`.
- Inputs: `det-list.txt` (52 camera JPEGs, from mojo-faces `.work/det/list.txt`), `index-list.txt` (first 12 of those),
  `MANIFEST.sha256` (lists, photos, model and tokenizer files; `sha256sum -c` clean at creation).
- Not done: decode of images for oracle output; SigLIP oracle uses dummy token ids, not the tokenizer.

## P2 (H1 for S1: R5, R6, R2a)

- R5 zoo detector: det_10g (SCRFD-10G) is the only detector on disk with an audited graph. retinaface_10g is a second candidate, licence UNKNOWN. No file for the R5 "other detector" in the plan.
- R6 text tower: v1 = `siglip-b16-224-v1` (Apache-2.0 per README front matter, presumed kept). Text input `input_ids` i64 (batch, seq). Tokenizer `siglip-b16-224-tok/tokenizer.json`.
- R6 v2 pin: NONE on disk (SigLIP2 row ABSENT in models.tsv). Not fetched. BLOCK for the v2 arm until S1 names an export and H1 adds its row.
- R6 PyTorch oracle (cosine 0.999 on 200 prompts): BLOCK. `torch` and `tokenizers` not importable in the system python. Oracle so far is ORT only (`gen_ort.py`), and its siglip mode feeds random ids, not tokenized text.
- R18a: `faces-expr/expr7-fer-plus-s0.onnx` and `expr7-fer-s2.onnx`. Input `x` f32 (b,1,48,48), output `logits` f32 (b,7). Licence and class names UNVERIFIED. Op audit NOT DONE (onnx package absent).
- Oracle outputs of P0 unchanged; no new fixtures were generated in P2.
