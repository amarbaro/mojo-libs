# Job for cvhelp: op inventory of the SigLIP ONNX

Wait until `~/Models/siglip-base-patch16-224-onnx/onnx/model.onnx` is exactly 813080024 bytes (`stat -c %s`); a download is running, do not touch it.
Then, from `~/Projects/mojo/mojo-cv`, run `.work/onnx_dump ~/Models/siglip-base-patch16-224-onnx/onnx/model.onnx > .work/siglip_dump.txt` (built from mojo-faces `tests/onnx_dump.mojo`; if it prints "truncated field" the file is still short).
Write `.work/siglip_ops.md` with: graph inputs and outputs (names, dims), every distinct node op type with its count, the ops mojo-faces does not run
(it runs Add AveragePool BatchNormalization Concat Conv Flatten Gather Gemm MaxPool Mul PRelu Relu Reshape Resize Shape Sigmoid Slice Transpose Unsqueeze),
and the node list of ONE vision encoder layer (names, ops, attributes, initializer dims) in file order. Numbers and names only, no weights.
Reply: `herd tell wYQ:p1 "DONE siglip-ops -> .work/siglip_ops.md"` (assetscv is the pane that asked).
