# ASTRA consult 1: vattn kernel vs AOTriton, layout finding (2026-10-06)

Read-only. Write your answer to `/home/mario/Projects/mojo/mojo-vattn/briefs/astra-consult-1-answer.md`,
reply only "written to <path>". Web facts only via crawl4ai MCP, cite URL, else "not known". No em dashes.

## Context
Plan: `/home/mario/Projects/mojo/mojo-vattn/docs/plan.md`. Kernel: `vattn.mojo` (Mojo 1.0 WMMA flash
attention, D=128, non-causal, [L,H,D] f16). Prereg: `bench/prereg-S3.md`. Logs: `.work/arms-r1.log`,
`.work/arms-r2.log`. Shape L=32760 H=40 D=128 B=1 (Wan 2.2 i2v self-attention, 2.198e13 FLOP/call).

## Measurements (all under gpu-wait, RX 7900 XTX, torch 2.13 rocm7.2, AOTriton `attn_fwd`)
| arm | ms/call | TFLOPS |
|---|---|---|
| torch SDPA on [B,H,L,D] strided views (what ComfyUI passes: `x.view(B,L,H,D).transpose(1,2)`, strides (L*H*D, D, H*D, 1)) | 1701 / 2157 / 2290 (profiler) | 10-13 |
| torch SDPA on the same data made `.contiguous()` | **278.5** | **79** |
| torch SDPA randn strided | 1212 | 18 |
| torch SDPA bf16 strided | 1277 | 17 |
| ComfyUI in-situ (torch.profiler, step 3, 80 attn_fwd calls incl. 40 small cross-attn) | ~885 implied | ~25 |
| vattn BM128 BN64 (237 VGPR, 0 spill) | 309-595 (spread 50 %, power-cap 290 W swings) | 37-71 |
| vattn BM128 BN32 (219 VGPR) | 392-765 | 29-56 |
| vattn BM64 BN32 (208 VGPR) | 1423-2409 | 9-15 |
Parity: vattn real-dump max abs err 2.786e-3 == SDPA's own vs f32 reference (mean 8.08e-5 both).

## Questions
1. Why would AOTriton be ~6x slower on the strided [B,H,L,D] views than contiguous? Is this a known AOTriton/ROCm behaviour (stride handling, kernel variant selection, no head-major locality)? Does it explain the ComfyUI in-situ ~885 ms (between the two)?
2. Given contiguous AOTriton = 79 TFLOPS (63 % of the 125.4 roof), is a custom kernel still worth it, or should the plan pivot to: patch ComfyUI's Wan attention to pass contiguous q/k/v (cost: 3 transposes of 335 MB, plus output)? Estimate the transpose cost and net per-step saving.
3. If the kernel continues: what in vattn.mojo most likely limits it (Q in registers + S + P + O acc at 219-237 VGPR = 1 wave/SIMD occupancy? V^T scatter store into LDS? single-buffered LDS? no head-major locality since our [L,H,D] layout strides keys by H*D=5120)? Rank the next 3 changes.
4. Our timing spread (power cap swings): better instrument than perf_counter around N calls?
