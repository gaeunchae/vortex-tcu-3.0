// sgemm2_tcu_dxa_mcast — X-axis-cluster multicast variant of sgemm2_tcu_dxa.
//
// sgemm2_tcu_dxa's CTA tile is M-heavy (cta_M = warps * tileM, tileN fixed),
// so A dominates the DXA traffic: at -w4 the tile is 64x8 and A is 8x the
// size of B. The shareable operand here is therefore A, not B.
//
// `mc_group_size` CTAs consecutive along blockIdx.X form a cluster. They share
// blockIdx.y, hence the same tile_row, hence the same A tile: read GMEM once
// and scatter to every member's LMEM. Each member still fetches its own B tile
// (distinct tile_col).
//
// Two constraints, NEITHER checked by hardware or the runtime:
//   * the host MUST set li.cluster_dim[0] = mc_group_size. Without it
//     cluster_size defaults to 1, get_cluster_rank() (= CTA_ID % cluster_size)
//     is 0 for EVERY CTA, and all of them fire the multicast -- over-releasing
//     receivers' event barriers. It is also what makes the cluster's LMEM
//     reservation contiguous, which the scatter addressing depends on.
//   * warps_per_cta * mc_group_size <= VX_CFG_NUM_WARPS, else members 2..K
//     never get warp slots while member 1 waits on the group barrier => hang.

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

__kernel void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  const uint32_t N             = arg->N;
  const uint32_t K             = arg->K;
  const uint32_t cta_M         = arg->cta_M;
  const uint32_t mc_group_size = arg->mc_group_size;

  const uint32_t tid       = threadIdx.x;
  const uint32_t warp_rank = tid / VX_CFG_NUM_THREADS;
  const uint32_t tile_row  = blockIdx.y * cta_M;
  const uint32_t tile_col  = blockIdx.x * ctx::tileN;

  // Shared memory: A [cta_M x tileK] row-major, B [tileN x tileK] col-major.
  auto smem   = reinterpret_cast<ctx::input_t *>(__local_mem());
  auto A_smem = smem;
  auto B_smem = smem + cta_M * ctx::tileK;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;
  ctx::fill_fragment(fragC, 0);

  // local_A — per-CTA bar receiving the multicast release.
  // local_B — per-CTA bar for this CTA's own B fetch.
  // group_A — cluster-wide rendezvous; dxa_multicast_2d uses it to guarantee
  //           every member has called expect_tx before rank-0 fires, and to
  //           keep rank-0 from overwriting A while a member still reads it.
  vortex::barrier       local_A(0);
  vortex::barrier       local_B(1);
  vortex::group_barrier group_A(2, mc_group_size);
  const bool is_dxa_warp = (get_sub_group_id() == 0);

  for (uint32_t k = 0; k < K; k += ctx::tileK) {
    if (is_dxa_warp) {
      // ctor does local_A.expect_tx(1) + precomputes the full-cluster mask.
      vortex::dxa_multicast_2d mc_A(kDescA, mc_group_size, local_A, group_A);

      // B is per-CTA, issued normally.
      local_B.expect_tx(1);
      vx_dxa_issue_2d_wg(kDescB, local_B.id(), B_smem, k, tile_col);

      // K-way rendezvous, then cluster rank-0 alone fires the A multicast.
      mc_A.sync_and_issue(A_smem, /*coord0=*/k, /*coord1=*/tile_row);
    }

    // Must be called from ALL warps of the CTA, not just the loader: these
    // wait on arrivals == warps_per_CTA AND events_r == 0.
    local_A.arrive_and_wait();
    local_B.arrive_and_wait();

    auto A_warp = A_smem + warp_rank * ctx::tileM * ctx::tileK;
    ctx::load_matrix_sync(fragA, A_warp, ctx::tileK);
    ctx::load_matrix_sync<vt::col_major>(fragB, B_smem, ctx::tileK);
    ctx::mma_sync(fragC, fragA, fragB, fragC);

    // Sync before the next iteration's DXA can overwrite SMEM.
    local_A.arrive_and_wait();
    local_B.arrive_and_wait();
  }

  auto pTileC = pC + (tile_row + warp_rank * ctx::tileM) * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}
