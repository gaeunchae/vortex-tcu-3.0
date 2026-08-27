#ifndef _SGEMM2_TCU_DXA_MCAST_COMMON_H_
#define _SGEMM2_TCU_DXA_MCAST_COMMON_H_

#include <stdint.h>

#ifndef VX_CFG_NUM_THREADS
#define VX_CFG_NUM_THREADS 4
#endif

#ifndef ITYPE
#define ITYPE fp16
#endif

#ifndef OTYPE
#define OTYPE fp32
#endif

// X-axis-cluster multicast variant of sgemm2_tcu_dxa. `mc_group_size` CTAs
// co-resident on one core share the same A tile (same blockIdx.y => same
// tile_row) via DXA multicast; each CTA fetches its own B tile.
typedef struct {
  uint32_t M, N, K;
  uint32_t cta_M;
  uint32_t mc_group_size;
  uint64_t A_addr;
  uint64_t B_addr;
  uint64_t C_addr;
} kernel_arg_t;

#endif
