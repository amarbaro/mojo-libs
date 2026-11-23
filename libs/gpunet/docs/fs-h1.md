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
