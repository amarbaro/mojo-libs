# mojo-vattn

Flash-attention forward for video DiT self-attention (Wan 2.2) on RX 7900 XTX (gfx1100), Mojo 1.0.
Non-causal, no mask, f16 in/out, f32 accumulate, head_dim 128, layout `[L, H, D]` (what Wan passes flat).

Build (CPU, no GPU needed): `~/Projects/mojo/mojo-baro/.venv/bin/mojo build run_vattn.mojo -I . -o .work/run_vattn`
Parity (GPU): `gpu-wait run --vram 4 --timeout 600 -- bench/parity.sh .work/case-*`
Cases: `python3 tools/vattn-ref.py gen DIR L H SEED` (fp64 reference over the same f16 bytes).

Plan and stages: `docs/plan.md`. Results: Brain `mojo/mojo-vattn/`.
