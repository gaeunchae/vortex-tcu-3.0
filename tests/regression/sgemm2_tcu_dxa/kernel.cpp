// sgemm2_tcu_dxa -- sgemm2_tcu with DXA descriptors replacing the scalar
// staging loop. Two LMEM staging slots overlap the next DXA transfer with
// WMMA consumption of the current slot.
//
// Layout note: sgemm2_tcu transposes B during staging (DRAM B is [N][K]
// col-major, smem B is [K][N] row-major). DXA does not transpose, so B stays
// [tileN][chunk] in smem and the fragment is loaded col_major with
// ldm=chunk -- the same form sgemm_tcu uses against DRAM.
//
// CHUNK_K stays compile-time so that fragment address generation folds and the
// WMMA inner loop can unroll. The old single-buffer implementation found that
// larger chunks did not help; this double-buffered version changes that
// trade-off and should be measured independently.

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
// Default chunk = 2 * tileK, i.e. two WMMA k-steps per DXA round trip.
// Measured on U55C fp16 512x3072x3072 -w1, double-buffered, verification on
// (tileK is 16 there, so this default is CHUNK_K=32):
//   chunk   cycles       instrs       IPC
//    16   390,174,859  155,910,176   0.400
//    32   339,838,578  128,188,448   0.377   <-- default
//    64   342,992,540  114,327,584   0.333
//   128   356,180,658  122,290,208   0.343
//   256   393,960,622  139,812,896   0.355
// Not monotonic: instructions bottom out at 64 but cycles bottom out at 32,
// because IPC falls as the chunk grows. Past 64 the instruction count climbs
// again -- the inner loop stops fully unrolling and loop overhead returns.
// So 64 has the higher ceiling (114M instrs => 42 MAC/cyc at IPC 1.0 vs 38 for
// 32) and would win if whatever depresses its IPC were found and fixed.
//
// Expressed as a multiple of tileK, not as a literal 32: tileK is
// xtileK * (4 / sizeof(dtype)), so a hard-coded 32 would silently mean one
// chunk (no double-step) for int8/int4. Only fp16 was measured.
#ifndef CHUNK_K
#define CHUNK_K 0            // 0 => 2 * tileK
#endif
constexpr uint32_t kChunkK = (CHUNK_K == 0) ? (2 * ctx::tileK) : (uint32_t)CHUNK_K;
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

  // Two LMEM staging slots. A is [cta_M x chunk_K] row-major and B is
  // [tileN x chunk_K] col-major in each slot.
  auto smem    = reinterpret_cast<ctx::input_t *>(__local_mem());
  auto A_smem0 = smem;
  auto B_smem0 = A_smem0 + cta_M * kChunkK;
  auto A_smem1 = B_smem0 + ctx::tileN * kChunkK;
  auto B_smem1 = A_smem1 + cta_M * kChunkK;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;
  ctx::fill_fragment(fragC, 0);

  vortex::barrier bar0(0);
  vortex::barrier bar1(1);

  // Only sub-group 0 issues DXA commands; the rank is stable across CTA recycling.
  const bool is_dxa_warp = (get_sub_group_id() == 0);

  // Prime slot 0. Every later slot is issued while the preceding slot is
  // consumed by WMMA.
  if (is_dxa_warp) {
    bar0.expect_tx(2);
    vx_dxa_issue_2d_wg(kDescA, bar0.id(), A_smem0, 0, tile_row);
    vx_dxa_issue_2d_wg(kDescB, bar0.id(), B_smem0, 0, tile_col);
  }

  for (uint32_t k0 = 0; k0 < K; k0 += kChunkK) {
    const bool use_slot0 = ((k0 / kChunkK) & 1u) == 0;

    // Register and issue the next slot before any warp can reach its barrier.
    // This keeps expect_tx in the same barrier generation as its DXA releases.
    const uint32_t next_k = k0 + kChunkK;
    if (next_k < K && is_dxa_warp) {
      if (use_slot0) {
        bar1.expect_tx(2);
        vx_dxa_issue_2d_wg(kDescA, bar1.id(), A_smem1, next_k, tile_row);
        vx_dxa_issue_2d_wg(kDescB, bar1.id(), B_smem1, next_k, tile_col);
      } else {
        bar0.expect_tx(2);
        vx_dxa_issue_2d_wg(kDescA, bar0.id(), A_smem0, next_k, tile_row);
        vx_dxa_issue_2d_wg(kDescB, bar0.id(), B_smem0, next_k, tile_col);
      }
    }

    // Wait for the current slot's transfers. The second wait below prevents
    // a later iteration from overwriting this slot before every warp has
    // finished its WMMA reads.
    if (use_slot0) {
      bar0.arrive_and_wait();
    } else {
      bar1.arrive_and_wait();
    }

    auto A_smem = use_slot0 ? A_smem0 : A_smem1;
    auto B_smem = use_slot0 ? B_smem0 : B_smem1;
    auto A_warp = A_smem + warp_rank * ctx::tileM * kChunkK;
    for (uint32_t kk = 0; kk < kChunkK; kk += ctx::tileK) {
      ctx::load_matrix_sync(fragA, A_warp + kk, kChunkK);
      ctx::load_matrix_sync<vt::col_major>(fragB, B_smem + kk, kChunkK);
      ctx::mma_sync(fragC, fragA, fragB, fragC);
    }

    if (use_slot0) {
      bar0.arrive_and_wait();
    } else {
      bar1.arrive_and_wait();
    }
  }

  // Each warp stores its (tileM x tileN) output tile.
  auto pTileC = pC + (tile_row + warp_rank * ctx::tileM) * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}
