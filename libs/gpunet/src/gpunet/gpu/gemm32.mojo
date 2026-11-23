# Copied from mojo-baro kernels/matmul.mojo @ 32408f3 (amar_matmul_regtile, unchanged): fp32 GEMM, gfx1100.
from max.gpu.memory import AddressSpace
from max.gpu.sync import barrier
from max.gpu import block_idx, thread_idx
from layout import TileTensor, TensorLayout, row_major, stack_allocation

comptime dtype = DType.float32

# --- Register-tiled variant -------------------------------------------------
# Each thread computes a TM x TN patch of C instead of a single element, so the
# values loaded from shared memory are reused TM/TN times in registers. This is
# where the arithmetic intensity comes from: the tiled kernel above is still
# bound by shared-memory traffic, one load per multiply-add.

comptime BM = 32
comptime BN = 32
comptime BK = 8
comptime TM = 2
comptime TN = 2
comptime NTHREADS = (BM // TM) * (BN // TN)  # 256


def amar_matmul_regtile[
    ALayout: TensorLayout, BLayout: TensorLayout, CLayout: TensorLayout
](
    A: TileTensor[dtype, ALayout, MutAnyOrigin],
    B: TileTensor[dtype, BLayout, MutAnyOrigin],
    C: TileTensor[dtype, CLayout, MutAnyOrigin],
    m: Int32,
    n: Int32,
    k_dim: Int32,
):
    comptime assert A.flat_rank == 2 and B.flat_rank == 2 and C.flat_rank == 2

    var M = Int(m)
    var N = Int(n)
    var K = Int(k_dim)

    var tx = thread_idx.x
    var ty = thread_idx.y
    var tid = ty * (BN // TN) + tx

    var block_row = block_idx.y * BM
    var block_col = block_idx.x * BN

    var sa = stack_allocation[dtype, address_space=AddressSpace.SHARED](
        row_major[BM, BK]()
    )
    var sb = stack_allocation[dtype, address_space=AddressSpace.SHARED](
        row_major[BK, BN]()
    )
    # SIMD values, not stack_allocation: a stack allocation here is scratch
    # memory, which on AMD lives in device memory and made this kernel slower
    # than the naive one. Comptime-unrolled indices keep these in registers.
    var acc = SIMD[dtype, TM * TN](0)

    var k_tile = 0
    while k_tile < K:
        # 256 threads cooperatively stage BM*BK and BK*BN elements: 4 each.
        comptime for i in range(BM * BK // NTHREADS):
            var e = tid + i * NTHREADS
            var r = e // BK
            var c = e % BK
            var gr = block_row + r
            var gc = k_tile + c
            if gr < M and gc < K:
                sa[r, c] = rebind[sa.ElementType](A[gr, gc])
            else:
                sa[r, c] = 0

        comptime for i in range(BK * BN // NTHREADS):
            var e = tid + i * NTHREADS
            var r = e // BN
            var c = e % BN
            var gr = k_tile + r
            var gc = block_col + c
            if gr < K and gc < N:
                sb[r, c] = rebind[sb.ElementType](B[gr, gc])
            else:
                sb[r, c] = 0
        barrier()

        # Outer product: one shared read feeds TN (or TM) fused multiply-adds.
        for k in range(BK):
            var a_reg = SIMD[dtype, TM](0)
            comptime for i in range(TM):
                a_reg[i] = rebind[Scalar[dtype]](sa[ty * TM + i, k])
            var b_reg = SIMD[dtype, TN](0)
            comptime for j in range(TN):
                b_reg[j] = rebind[Scalar[dtype]](sb[k, tx * TN + j])
            comptime for i in range(TM):
                comptime for j in range(TN):
                    acc[i * TN + j] += a_reg[i] * b_reg[j]
        barrier()
        k_tile += BK

    comptime for i in range(TM):
        comptime for j in range(TN):
            var r = block_row + ty * TM + i
            var c = block_col + tx * TN + j
            if r < M and c < N:
                C[r, c] = rebind[C.ElementType](acc[i * TN + j])
