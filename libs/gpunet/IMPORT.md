# gpunet import record

Additive import of the mojo-faces runtime (full-stack plan 3.1, step 1, gate G1.1). Nothing was edited in the imported files except
their import lines.

- Source repo: `mojo-faces` (`~/Projects/mojo/mojo-faces`).
- Source SHA: **deea3f5** (`deea3f5d0398586d47e3bf58e08c84d1f6eb548b`, "chore: point library paths at the mojo-libs monorepo"). The
  six files have the same blobs at the later faces base `d89c6d5`; the SHA, not a history, is the provenance (a cross-repo copy keeps no history).
- Method: `git -C mojo-faces show deea3f5:<path>`, then every import line rewritten (`faces.onnx` to `gpunet.onnx`, `faces.nn` to
  `gpunet.nn`, `faces.gpu.X` to `gpunet.gpu.X`). `scripts/ci.sh` repeats that comparison on every run.

| faces path (at deea3f5) | blob | gpunet path | LOC |
|---|---|---|---|
| `src/faces/onnx.mojo` | 108906d | `src/gpunet/onnx.mojo` | 308 |
| `src/faces/nn.mojo` | c69f385 | `src/gpunet/nn.mojo` | 666 |
| `src/faces/gpu/net.mojo` | 3e37c72 | `src/gpunet/gpu/net.mojo` | 965 |
| `src/faces/gpu/kernels.mojo` | bbdb7fc | `src/gpunet/gpu/kernels.mojo` | 276 |
| `src/faces/gpu/gemm16.mojo` | d83caf4 | `src/gpunet/gpu/gemm16.mojo` | 167 |
| `src/faces/gpu/gemm32.mojo` | a2e039d | `src/gpunet/gpu/gemm32.mojo` | 102 |

2,484 LOC. Stays in faces: `src/faces/gpu/detect.mojo` (`detect_gpu`: `Face`, letterbox and decode around `GpuNet`) and the SCRFD
adapter (`src/faces/detect.mojo`).

## Notices kept

- `LICENSE`: the Apache-2.0 text of mojo-faces at deea3f5 (`git show deea3f5:LICENSE`, sha256 `c75eabbf...cfaf`). mojo-faces has no `NOTICE` file at that SHA.
- File headers, verbatim: `gemm32.mojo` line 1 "Copied from mojo-baro kernels/matmul.mojo @ 32408f3 (amar_matmul_regtile, unchanged): fp32 GEMM, gfx1100.";
  `gemm16.mojo` line 1 "Copied from mojo-baro kernels/matmul_wmma_lds.mojo @ 32408f3 (unchanged but the mma import): fp16 WMMA GEMM, gfx1100."

## Layering

The runtime imports `std`, `max`, `layout` and `mmap` only. It imports nothing from faces and nothing from mojocv (plan 3.1 item 4
allowed `mojocv.mat.Mat`; the six files do not use it). Build flags: `-I libs/gpunet/src -I libs/mmap/src` (`--target-accelerator gfx1100` for the GPU runner).

## Cutover state (R1b)

The faces modules `faces.{onnx,nn}` and `faces.gpu.{net,kernels,gemm16,gemm32}` are one-line re-export shims of this package until
retirement (R1c). Faces and CV callers import `gpunet.*` directly. Mutant gates (faces `tests/check_gpu.sh`, `tests/check_siglip.sh`)
mutate a copy of `libs/gpunet/src`.
