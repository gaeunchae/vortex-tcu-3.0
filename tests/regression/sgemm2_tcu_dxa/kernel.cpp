#include "common.h"
#include <vx_spawn2.h>
#include <vx_tensor.h>
#include <vx_intrinsics.h>
#include <vx_dxa.h>
#include <vx_barrier.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<VX_CFG_NUM_THREADS, vt::ITYPE, vt::OTYPE>;

// DXA descriptor slots (programmed by the host in main.cpp).
constexpr uint32_t kDescA = 0;
constexpr uint32_t kDescB = 1;

// sgemm2_tcu with the cooperative DRAM->LMEM staging loops replaced by DXA.
//
// sgemm2_tcu stages both tiles with scalar per-element loads:
//   A_smem[r * tileK + c] = pA[(tile_row + r) * K + (k + c)];
// which costs ~4.7x the instructions of the direct-from-DRAM sgemm_tcu.
// Here a single warp issues two 2D DXA descriptor copies instead, and the
// whole CTA waits on one transaction barrier.
//
// Layout note: sgemm2_tcu transposes B during staging (DRAM B is [N][K]
// col-major, smem B is [K][N] row-major). DXA does not transpose, so B stays
// [tileN][tileK] in smem and the fragment is loaded col_major with ldm=tileK
// -- the same form sgemm_tcu uses against DRAM.
__kernel void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  uint32_t N = arg->N;
  uint32_t K = arg->K;
  uint32_t cta_M = arg->cta_M;

  uint32_t tid = threadIdx.x;
  uint32_t warp_rank = tid / VX_CFG_NUM_THREADS;

  uint32_t tile_row = blockIdx.y * cta_M;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  // Shared memory: A [cta_M x tileK] row-major, B [tileN x tileK] col-major
  auto smem   = reinterpret_cast<ctx::input_t *>(__local_mem());
  auto A_smem = smem;
  auto B_smem = smem + cta_M * ctx::tileK;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;
  ctx::fill_fragment(fragC, 0);

  vortex::barrier bar(0);

  // Only sub-group 0 issues DXA commands; the rank is stable across CTA recycling.
  const bool is_dxa_warp = (get_sub_group_id() == 0);

  for (uint32_t k = 0; k < K; k += ctx::tileK) {
    if (is_dxa_warp) {
      bar.expect_tx(2); // two pending transactions: A + B
      vx_dxa_issue_2d_wg(kDescA, bar.id(), A_smem, k, tile_row);
      vx_dxa_issue_2d_wg(kDescB, bar.id(), B_smem, k, tile_col);
    }

    // DXA completion + CTA sync
    bar.arrive_and_wait();

    auto A_warp = A_smem + warp_rank * ctx::tileM * ctx::tileK;
    ctx::load_matrix_sync(fragA, A_warp, ctx::tileK);
    ctx::load_matrix_sync<vt::col_major>(fragB, B_smem, ctx::tileK);
    ctx::mma_sync(fragC, fragA, fragB, fragC);

    // hold the tiles until every warp has consumed them
    bar.arrive_and_wait();
  }

  // Each warp stores its (tileM x tileN) output tile.
  auto pTileC = pC + (tile_row + warp_rank * ctx::tileM) * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}
