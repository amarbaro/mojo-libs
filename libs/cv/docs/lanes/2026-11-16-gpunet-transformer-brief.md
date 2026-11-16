# Brief: transformer ops on GpuNet (SigLIP vision tower on the 7900 XTX)

Goal: `GpuNet.run` executes the same SigLIP vision graph as the CPU runner, values equal to it, at a few hundred ms per image or better
(CPU: 7.7 s; the library has 4202 images). Repo `~/Projects/mojo/mojo-faces`, files `src/faces/gpu/net.mojo` (662 lines), `kernels.mojo`, `gemm32.mojo`, `gemm16.mojo`.
Read first: `docs/gpu.md`, `docs/rules.md`, mojo-faces `tests/check_siglip.sh` (the gate you extend), `~/Projects/mojo/mojo-cv/.work/siglip_ops.md`.

Ops to add on the device (everything else in the graph is host shape arithmetic and already works in `nn.mojo`: copy its handling of `ints`):
`MatMul` ([b, m, k] x [k, n] shared weight, and batched [b, h, m, k] x [b, h, k, n]; reuse `amar_matmul_regtile` / `amar_matmul_wmma_lds` from `gemm32/gemm16.mojo`,
the 1x1-conv path already skips im2col), `LayerNormalization` (axis -1, eps from the node, fp32 accumulate), `Softmax` (last axis), `Tanh`, `Exp`, `ReduceL2`+`Div`
(the final normalisation, can stay on the host: one 768-vector), float `Gather` of the position table, `Add`/`Mul` with the general broadcast of `nn.mojo broadcast2`.
GELU in this graph is `Tanh` inside Mul/Add nodes, not a Gelu op. Attention is MatMul, Softmax, MatMul: no fused kernel needed first.
Kernel sources to start from: `~/Projects/mojo/mojo-baro/kernels/` (layernorm, softmax, bmm); copy with a source note as `gemm32.mojo` does.

Gate: extend `tests/check_siglip.sh` with a GPU arm (`gpu-wait run --timeout S -- ...`): each of the 15 named values, GPU against the CPU runner and against onnxruntime,
fp32 arm cosine >= 0.99999, fp16 arm cosine >= 0.999 (state what you measured). One mutant per new kernel (a wrong epsilon, a softmax without the max subtraction)
must fail it. Numbers for the commit body: ms per image warm (fp32, fp16), device MB, as in `docs/gpu.md`.

Rules: a GPU job is `gpu-wait run --timeout S` always; `ROCR_VISIBLE_DEVICES=-1` does not stop `mojo build` from opening the card, build when it is quiet;
commit by path, no push; report `herd tell wXY:p1 "DONE gpunet-transformer -> <report file>"` with what passed and what failed.

## Added 2026-11-16 from cvint's note (`~/Brain/mojo-cv/2026-11-16-cvint-siglip-cpu-labels.md`)

- `Gather` along axis 1 on floats, in `faces.nn` (CPU) and on GpuNet: the SigLIP text graph takes its last token that way; `mcv-labels text` stops at the final
  LayerNorm and finishes in Mojo until this exists. Gate it with the text tower values against onnxruntime (cosine 1.0000000 on 12 texts is cvint's number to keep).
- `faces.nn.gemm` is a row-wise axpy without register tiling; a tiled micro-kernel for the CPU runner is the next lever if the full-library SigLIP run stays slow
  (cvint measured 1.4 s per picture solo, 0.28 pictures/s under load with three shards). Measure before and after in alternating rounds.
