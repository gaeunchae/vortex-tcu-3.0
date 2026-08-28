// sgemm2_tcu_dxa -- sgemm2_tcu with DXA descriptors replacing the scalar
// staging loop, staging CHUNK_K columns of K per DXA round trip.
//
// Layout note: sgemm2_tcu transposes B during staging (DRAM B is [N][K]
// col-major, smem B is [K][N] row-major). DXA does not transpose, so B stays
// [tileN][chunk] in smem and the fragment is loaded col_major with
// ldm=chunk -- the same form sgemm_tcu uses against DRAM.
//
// CHUNK_K > tileK was measured and does NOT help -- do not re-propose it.
// The theory was that chunk == tileK degenerates to
//   issue DMA(k) -> barrier -> mma(k) -> barrier -> issue DMA(k+1) -> ...
// overlapping nothing, at ~1033 cyc per k-step of which only ~64 are MAC, so
// folding K=128 into ONE DMA pair should amortise the HBM latency away.
// U55C 512x512x128, cycles at CHUNK_K = 0 / 64 / 128:
//   fp16  4,231,237 / 4,260,694 / 4,279,950   (monotonically WORSE)
//   int8  2,952,127 / 2,805,527 / 2,917,447   (noise, no trend)
// So the loop is not DMA-round-trip bound. The cost is the two CTA-wide
// barriers, which chunking does not remove -- it only makes them rarer while
// each one stalls longer. The real lever is fewer warps per CTA: -w1 gives
// four independent single-warp CTAs with no cross-warp barrier at all and
// measures 3,685,490, beating both this kernel at -w4 and sgemm_tcu.
//
// An earlier version of this measurement appeared to show a win. It did not:
// the "win" was an artifact of chunk being a runtime arg (see below), which
// inflated the chunk == tileK baseline. Keep it compile-time.

#include "common.h"
#include <vx_spawn2.h>
#include <vx_tensor.h>
#include <vx_intrinsics.h>
#include <vx_dxa.h>
#include <vx_barrier.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<VX_CFG_NUM_THREADS, vt::ITYPE, vt::OTYPE>;

constexpr uint32_t kDescA = 0;
constexpr uint32_t kDescB = 1;

// The chunk depth MUST be compile-time. As a runtime kernel arg it cost +27%
// static instructions on the card (989,216 -> 1,259,552 at chunk == tileK):
// the ldm handed to load_matrix_sync stops being a constant, so fragment
// address generation no longer folds and the inner loop no longer unrolls.
// That loss is larger than the DMA-round-trip win it was meant to enable.
#ifndef CHUNK_K
#define CHUNK_K 0            // 0 => tileK, i.e. one DMA pair per k-step
#endif
constexpr uint32_t kChunkK = (CHUNK_K == 0) ? ctx::tileK : (uint32_t)CHUNK_K;
static_assert(kChunkK % ctx::tileK == 0, "CHUNK_K must be a multiple of tileK");

__kernel void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  const uint32_t N       = arg->N;
  const uint32_t K       = arg->K;
  const uint32_t cta_M   = arg->cta_M;

  const uint32_t tid       = threadIdx.x;
  const uint32_t warp_rank = tid / VX_CFG_NUM_THREADS;
  const uint32_t tile_row  = blockIdx.y * cta_M;
  const uint32_t tile_col  = blockIdx.x * ctx::tileN;

  // Shared memory: A [cta_M x chunk_K] row-major, B [tileN x chunk_K] col-major.
  // Row stride is chunk_K, so that is the ldm handed to load_matrix_sync.
  auto smem   = reinterpret_cast<ctx::input_t *>(__local_mem());
  auto A_smem = smem;
  auto B_smem = smem + cta_M * kChunkK;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;
  ctx::fill_fragment(fragC, 0);

  vortex::barrier bar(0);

  // Only sub-group 0 issues DXA commands; the rank is stable across CTA recycling.
  const bool is_dxa_warp = (get_sub_group_id() == 0);

  for (uint32_t k0 = 0; k0 < K; k0 += kChunkK) {
    if (is_dxa_warp) {
      bar.expect_tx(2); // two pending transactions: A + B
      vx_dxa_issue_2d_wg(kDescA, bar.id(), A_smem, k0, tile_row);
      vx_dxa_issue_2d_wg(kDescB, bar.id(), B_smem, k0, tile_col);
    }

    // DXA completion + CTA sync
    bar.arrive_and_wait();

    // Whole chunk consumed from LMEM -- no DMA and no barrier in here.
    auto A_warp = A_smem + warp_rank * ctx::tileM * kChunkK;
    for (uint32_t kk = 0; kk < kChunkK; kk += ctx::tileK) {
      ctx::load_matrix_sync(fragA, A_warp + kk, kChunkK);
      ctx::load_matrix_sync<vt::col_major>(fragB, B_smem + kk, kChunkK);
      ctx::mma_sync(fragC, fragA, fragB, fragC);
    }

    // hold the tiles until every warp has consumed them
    bar.arrive_and_wait();
  }

  // Each warp stores its (tileM x tileN) output tile.
  auto pTileC = pC + (tile_row + warp_rank * ctx::tileM) * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}
