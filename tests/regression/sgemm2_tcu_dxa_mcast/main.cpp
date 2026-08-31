#include "common.h"
#include <chrono>
#include <cmath>
#include <iostream>
#include <cstdlib>
#include <rvfloats.h>
#include <string.h>
#include <tensor_cfg.h>
#include <unistd.h>
#include <util.h>
#include <vector>
#include <vortex2.h>
#include <dxa.h>

#define FLOAT_ULP 10
#define MAX_ERRORS 100

#define RT_CHECK(_expr)                                      \
  do {                                                       \
    int _ret = _expr;                                        \
    if (0 == _ret)                                           \
      break;                                                 \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret); \
    cleanup();                                               \
    exit(-1);                                                \
  } while (false)

using namespace vortex;
namespace vt = tensor;

///////////////////////////////////////////////////////////////////////////////

template <typename T>
static void convert_row_to_col_major(T *dst, const T *src, uint32_t rows, uint32_t cols) {
  for (uint32_t r = 0; r < rows; ++r) {
    for (uint32_t c = 0; c < cols; ++c) {
      dst[c * rows + r] = src[r * cols + c];
    }
  }
}

static void convert_row_to_col_major_4bit(uint8_t *dst, uint32_t width, uint32_t height, const uint8_t *src) {
  // Calculate output size and stride
  uint32_t out_bytes = (width * height + 1) / 2;
  memset(dst, 0, out_bytes);
  uint32_t dst_stride = (height + 1) / 2; // Bytes per column in output

  // For each column in source (which becomes row in destination)
  for (uint32_t c = 0; c < width; ++c) {
    uint32_t base = c * dst_stride;

    // For each row in source (which becomes column in destination)
    for (uint32_t r = 0; r < height; r += 2) {
      // Calculate source indices (row-major)
      uint32_t idx_even = r * width + c;
      uint32_t idx_odd = (r + 1) * width + c;

      // Extract nibbles - consistent with data_accessor_t
      uint8_t b_even = src[idx_even / 2];
      uint8_t b_odd = (r + 1 < height) ? src[idx_odd / 2] : 0;

      uint8_t nib_even = (idx_even & 1) ? (b_even >> 4) : (b_even & 0x0F);
      uint8_t nib_odd = (r + 1 < height)
                            ? ((idx_odd & 1) ? (b_odd >> 4) : (b_odd & 0x0F))
                            : 0;

      // Pack into destination: even row in low nibble, odd row in high nibble
      dst[base + r / 2] = (nib_odd << 4) | nib_even;
    }
  }
}

///////////////////////////////////////////////////////////////////////////////

template <typename T>
struct data_accessor_t {
  using Type = typename T::dtype;
  static Type read(const Type *ptr, uint32_t offset) {
    return ptr[offset];
  }
  static void write(Type *ptr, uint32_t offset, Type value) {
    ptr[offset] = value;
  }
};

template <>
struct data_accessor_t<vt::int4> {
  static uint8_t read(const uint8_t *ptr, uint32_t offset) {
    uint32_t row_off = offset / 2;
    bool odd = offset & 0x1;
    uint8_t value8 = ptr[row_off];
    return odd ? (value8 >> 4) : (value8 & 0x0f); // to nibble
  }
  static void write(uint8_t *ptr, uint32_t offset, int32_t value) {
    uint32_t row_off = offset / 2;
    bool odd = offset & 0x1;
    uint8_t old_value = ptr[row_off];
    uint8_t new_value = odd ? ((old_value & 0x0f) | (value << 4))
                            : ((old_value & 0xf0) | (value & 0x0f));
    ptr[offset / 2] = new_value;
  }
};

template <>
struct data_accessor_t<vt::uint4> {
  static uint8_t read(const uint8_t *ptr, uint32_t offset) {
    uint32_t row_off = offset / 2;
    bool odd = offset & 0x1;
    uint8_t value8 = ptr[row_off];
    return odd ? (value8 >> 4) : (value8 & 0x0f); // to nibble
  }
  static void write(uint8_t *ptr, uint32_t offset, int32_t value) {
    uint32_t row_off = offset / 2;
    bool odd = offset & 0x1;
    uint8_t old_value = ptr[row_off];
    uint8_t new_value = odd ? ((old_value & 0x0f) | (value << 4))
                            : ((old_value & 0xf0) | (value & 0x0f));
    ptr[offset / 2] = new_value;
  }
};

///////////////////////////////////////////////////////////////////////////////

template <typename Type>
class Comparator {};

template <>
class Comparator<vt::int8> {
public:
  static int8_t generate() {
    return (int8_t)rand();
  }
  static bool compare(int8_t a, int8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::uint8> {
public:
  static uint8_t generate() {
    return (uint8_t)rand();
  }
  static bool compare(uint8_t a, uint8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::int4> {
public:
  static uint8_t generate() {
    return (uint8_t)rand(); // store 2 nibbles in a byte
  }
  static bool compare(uint8_t a, uint8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::uint4> {
public:
  static uint8_t generate() {
    return (uint8_t)rand(); // store 2 nibbles in a byte
  }
  static bool compare(uint8_t a, uint8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::int32> {
public:
  static int32_t generate() {
    return (int32_t)rand();
  }
  static bool compare(int32_t a, int32_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::fp16> {
public:
  static uint16_t generate() {
    auto fvalue = float(rand()) / RAND_MAX;
    return rv_ftoh_s(bit_cast<uint32_t>(fvalue), 0, nullptr);
  }
  static bool compare(uint16_t a, uint16_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::bf16> {
public:
  static uint16_t generate() {
    auto fvalue = float(rand()) / RAND_MAX;
    return rv_ftob_s(bit_cast<uint32_t>(fvalue), 0, nullptr);
  }
  static bool compare(uint16_t a, uint16_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::fp8> {
public:
  static uint8_t generate() {
    auto fvalue = float(rand()) / RAND_MAX;
    return rv_ftoe4m3_s(bit_cast<uint32_t>(fvalue), 0, nullptr);
  }
  static bool compare(uint8_t a, uint8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::bf8> {
public:
  static uint8_t generate() {
    auto fvalue = float(rand()) / RAND_MAX;
    return rv_ftoe5m2_s(bit_cast<uint32_t>(fvalue), 0, nullptr);
  }
  static bool compare(uint8_t a, uint8_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::tf32> {
public:
  static uint32_t generate() {
    auto fvalue = float(rand()) / RAND_MAX;
    return rv_ftotf32_s(bit_cast<uint32_t>(fvalue), 0, nullptr);
  }
  static bool compare(uint32_t a, uint32_t b, int index, int errors) {
    if (a != b) {
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=0x%x, actual=0x%x\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<vt::fp32> {
public:
  static float generate() {
    return static_cast<float>(rand()) / RAND_MAX;
  }
  static bool compare(float a, float b, int index, int errors) {
    // Lower-precision inputs (fp8/bf8/fp16/bf16) accumulated into fp32
    // can drift well past the strict ULP=10 threshold used for fp32 inputs.
    // Use a relative-error tolerance for these -- this mirrors sgemm_tcu.
    constexpr bool low_prec_input =
        std::is_same<vt::ITYPE, vt::fp8>::value
     || std::is_same<vt::ITYPE, vt::bf8>::value
     || std::is_same<vt::ITYPE, vt::fp16>::value
     || std::is_same<vt::ITYPE, vt::bf16>::value;
    if constexpr (low_prec_input) {
      if (a == 0.0f && b == 0.0f) {
        return true;
      }
      // 1% relative error is comfortably above any single-element
      // mixed-precision accumulation drift seen on the regression
      // matrices, and tight enough to catch real systematic errors.
      auto diff = std::abs((a - b) / b);
      if (diff < 0.01f) {
        return true;
      }
      if (errors < MAX_ERRORS) {
        printf("*** error: [%d] expected=%f, actual=%f\n", index, b, a);
      }
      return false;
    } else {
      union fi_t {
        float f;
        int32_t i;
      };
      fi_t fa, fb;
      fa.f = a;
      fb.f = b;
      auto d = std::abs(fa.i - fb.i);
      if (d > FLOAT_ULP) {
        if (errors < MAX_ERRORS) {
          printf("*** error: [%d] expected=%f, actual=%f\n", index, fb.f, fa.f);
        }
        return false;
      }
      return true;
    }
  }
};

///////////////////////////////////////////////////////////////////////////////

template <typename S, typename D>
struct muladd_t {
  using stype = typename S::dtype;
  using dtype = typename D::dtype;
  static dtype eval(stype a, stype b, dtype c) {
    return static_cast<dtype>(a) * static_cast<dtype>(b) + c;
  }
};

template <>
struct muladd_t<vt::fp16, vt::fp32> {
  static float eval(uint16_t a, uint16_t b, float c) {
    auto fa = bit_cast<float>(rv_htof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_htof_s(b, 0, nullptr));
    return fa * fb + c;
  }
};

template <>
struct muladd_t<vt::fp16, vt::fp16> {
  static uint16_t eval(uint16_t a, uint16_t b, uint16_t c) {
    auto fa = bit_cast<float>(rv_htof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_htof_s(b, 0, nullptr));
    auto fc = bit_cast<float>(rv_htof_s(c, 0, nullptr));
    auto fd = fa * fb + fc;
    return rv_ftoh_s(bit_cast<uint32_t>(fd), 0, nullptr);
  }
};

template <>
struct muladd_t<vt::bf16, vt::fp32> {
  static float eval(uint16_t a, uint16_t b, float c) {
    auto fa = bit_cast<float>(rv_btof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_btof_s(b, 0, nullptr));
    return fa * fb + c;
  }
};

template <>
struct muladd_t<vt::bf16, vt::bf16> {
  static uint16_t eval(uint16_t a, uint16_t b, uint16_t c) {
    auto fa = bit_cast<float>(rv_btof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_btof_s(b, 0, nullptr));
    auto fc = bit_cast<float>(rv_btof_s(c, 0, nullptr));
    auto fd = fa * fb + fc;
    return rv_ftob_s(bit_cast<uint32_t>(fd), 0, nullptr);
  }
};

template <>
struct muladd_t<vt::fp8, vt::fp32> {
  static float eval(uint8_t a, uint8_t b, float c) {
    auto fa = bit_cast<float>(rv_e4m3tof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_e4m3tof_s(b, 0, nullptr));
    return fa * fb + c;
  }
};

template <>
struct muladd_t<vt::bf8, vt::fp32> {
  static float eval(uint8_t a, uint8_t b, float c) {
    auto fa = bit_cast<float>(rv_e5m2tof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_e5m2tof_s(b, 0, nullptr));
    return fa * fb + c;
  }
};

template <>
struct muladd_t<vt::tf32, vt::fp32> {
  static float eval(uint32_t a, uint32_t b, float c) {
    auto fa = bit_cast<float>(rv_tf32tof_s(a, 0, nullptr));
    auto fb = bit_cast<float>(rv_tf32tof_s(b, 0, nullptr));
    return fa * fb + c;
  }
};

template <>
struct muladd_t<vt::int4, vt::int32> {
  static int32_t eval(uint8_t a, uint8_t b, int32_t c) {
    int32_t a_val = a & 0xF;
    if (a & 0x8) {
      a_val |= 0xFFFFFFF0; // sign extend
    }
    int32_t b_val = b & 0xF;
    if (b & 0x8) {
      b_val |= 0xFFFFFFF0; // sign extend
    }
    return a_val * b_val + c;
  }
};

template <>
struct muladd_t<vt::uint4, vt::int32> {
  static int32_t eval(uint8_t a, uint8_t b, int32_t c) {
    int32_t a_val = a & 0xF;
    int32_t b_val = b & 0xF;
    return a_val * b_val + c;
  }
};

template <typename T>
inline typename T::dtype generate_A_value() {
  return Comparator<T>::generate();
}

template <typename T>
inline typename T::dtype generate_B_value() {
  return Comparator<T>::generate();
}

///////////////////////////////////////////////////////////////////////////////

using cfg = vt::wmma_config_t<VX_CFG_NUM_THREADS, vt::ITYPE, vt::OTYPE>;

using itype_t = typename vt::ITYPE::dtype;
using otype_t = typename vt::OTYPE::dtype;

static void matmul_cpu(otype_t *C, const itype_t *A, const itype_t *B, uint32_t M, uint32_t N, uint32_t K) {
  // K counts dtype units (bytes), so sub-byte types pack `subbytes` elements
  // per unit and the logical reduction depth is KS.
  uint32_t subbytes = 8 / vt::ITYPE::bits;
  uint32_t KS = subbytes ? (K * subbytes) : K;
  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      otype_t sum(0);
      for (uint32_t k = 0; k < KS; ++k) {
        auto a = data_accessor_t<vt::ITYPE>::read(A, m * KS + k);
        auto b = data_accessor_t<vt::ITYPE>::read(B, k * N + n);
        sum = muladd_t<vt::ITYPE, vt::OTYPE>::eval(a, b, sum);
      }
      data_accessor_t<vt::OTYPE>::write(C, m * N + n, sum);
    }
  }
}

///////////////////////////////////////////////////////////////////////////////

const char *kernel_file = "kernel.vxbin";

// DXA descriptor slots (must match kernel.cpp).
constexpr uint32_t kDescA = 0;
constexpr uint32_t kDescB = 1;

uint32_t xm = 64;
uint32_t xn = 64;
uint32_t xk = 64;
uint32_t warps = 1;
uint32_t mc_group = 4;

vx_device_h device = nullptr;
vx_buffer_h A_buffer = nullptr;
vx_buffer_h B_buffer = nullptr;
vx_buffer_h C_buffer = nullptr;
vx_queue_h  queue   = nullptr;
vx_module_h module_ = nullptr;
vx_kernel_h kernel  = nullptr;
kernel_arg_t kernel_arg = {};

static void show_usage() {
  std::cout << "Vortex Sgemm2 TCU Test." << std::endl;
  std::cout << "Usage: [-m: M] [-n: N] [-k: K] [-w: warps] [-g: mcast group] [-h: help]" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:k:w:g:h")) != -1) {
    switch (c) {
    case 'm':
      xm = atoi(optarg);
      break;
    case 'n':
      xn = atoi(optarg);
      break;
    case 'k':
      xk = atoi(optarg);
      break;
    case 'w':
      warps = atoi(optarg);
      break;
    case 'g':
      mc_group = atoi(optarg);
      break;
    case 'h':
      show_usage();
      exit(0);
      break;
    default:
      show_usage();
      exit(-1);
    }
  }
}

void cleanup() {
  if (device) {
    if (A_buffer) vx_buffer_release(A_buffer);
    if (B_buffer) vx_buffer_release(B_buffer);
    if (C_buffer) vx_buffer_release(C_buffer);
    if (kernel)  vx_kernel_release(kernel);
    if (module_) vx_module_release(module_);
    if (queue)   vx_queue_release(queue);
    vx_device_dump_perf(device, stdout);
    vx_device_release(device);
  }
}

int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  std::srand(50);

  std::cout << "open device connection" << std::endl;
  RT_CHECK(vx_device_open(0, &device));

  vx_queue_info_t qi = { sizeof(qi), nullptr, VX_QUEUE_PRIORITY_NORMAL, 0 };
  RT_CHECK(vx_queue_create(device, &qi, &queue));

  uint64_t isa_flags;
  RT_CHECK(vx_device_query(device, VX_CAPS_ISA_FLAGS, &isa_flags));
  bool has_ext = (isa_flags & VX_ISA_EXT_TCU) != 0;
  if (!has_ext) {
    std::cout << "TCU extension not supported!" << std::endl;
    cleanup();
    return -1;
  }

  uint64_t NT;
  RT_CHECK(vx_device_query(device, VX_CAPS_NUM_THREADS, &NT));
  if (NT != VX_CFG_NUM_THREADS) {
    std::cout << "Error: device warp size (" << NT << ") must match VX_CFG_NUM_THREADS=" << VX_CFG_NUM_THREADS << "!" << std::endl;
    return -1;
  }

  uint64_t num_warps;
  RT_CHECK(vx_device_query(device, VX_CAPS_NUM_WARPS, &num_warps));
  if (warps > num_warps) {
    std::cout << "Error: requested warps (" << warps << ") exceeds device's capacity (" << num_warps << ")" << std::endl;
    return -1;
  }

  if (mc_group == 0) {
    mc_group = 1;
  }

  // All mc_group CTAs must be co-resident on one core. VX_cta_dispatch admits
  // CTAs one at a time and only reserves LMEM for the whole cluster -- it does
  // NOT reserve warp slots. Exceeding the core's warp budget therefore hangs
  // (members 2..K wait for warps; member 1 waits for them on group_A).
  if ((uint64_t)warps * mc_group > num_warps) {
    std::cout << "Error: warps (" << warps << ") * mcast group (" << mc_group
              << ") = " << (warps * mc_group) << " exceeds device's warp capacity ("
              << num_warps << "); the cluster cannot be co-resident." << std::endl;
    return -1;
  }

  uint32_t M = xm;
  uint32_t N = xn;
  uint32_t K = xk;

  uint32_t cta_M = warps * cfg::tileM;
  uint32_t a_size = cta_M * cfg::tileK;
  uint32_t b_size = cfg::tileK * cfg::tileN;

  if ((a_size % (warps * NT)) != 0) {
    std::cerr << "Error: A_smem size (" << a_size
              << ") is not a multiple of CTA thread count (" << (warps * NT) << ")!" << std::endl;
    return -1;
  }

  if ((b_size % (warps * NT)) != 0) {
    std::cerr << "Error: B_smem size (" << b_size
              << ") is not a multiple of CTA thread count (" << (warps * NT) << ")!" << std::endl;
    return -1;
  }

  if ((M % cta_M) != 0) {
    std::cout << "Error: M (" << M << ") must be a multiple of cta_M=" << cta_M << "!" << std::endl;
    return -1;
  }

  if ((N % cfg::tileN) != 0) {
    std::cout << "Error: N (" << N << ") must be a multiple of tileN=" << cfg::tileN << "!" << std::endl;
    return -1;
  }

  if ((K % cfg::tileK) != 0) {
    std::cout << "Error: K (" << K << ") must be a multiple of tileK=" << cfg::tileK << "!" << std::endl;
    return -1;
  }

  size_t sizeA = M * K;
  size_t sizeB = K * N;
  size_t sizeC = M * N;
  uint32_t grid_dim[2]  = {N / cfg::tileN, M / cta_M};
  uint32_t block_dim[2] = {warps * (uint32_t)NT, 1};

  std::cout << "input data type: " << vt::ITYPE::name << " (id=" << vt::ITYPE::id << ")" << std::endl;
  std::cout << "output data type: " << vt::OTYPE::name << " (id=" << vt::OTYPE::id << ")" << std::endl;
  std::cout << "WMMA Core Dimension: M=" << cfg::tcM << ", N=" << cfg::tcN << ", K=" << cfg::tcK << std::endl;
  std::cout << "WMMA Per-Warp Tile: M=" << cfg::tileM << ", N=" << cfg::tileN << ", K=" << cfg::tileK << std::endl;
  std::cout << "WMMA CTA Tile: M=" << cta_M << ", N=" << cfg::tileN << ", K=" << cfg::tileK << std::endl;
  // The cluster spans blockIdx.X, so grid_dim[0] must be a whole multiple of
  // it (enforced in queue.cpp; VX_ERR_INVALID_VALUE otherwise).
  if ((grid_dim[0] % mc_group) != 0) {
    std::cout << "Error: grid_dim[0] (" << grid_dim[0]
              << ") must be a multiple of mcast group (" << mc_group << ")!" << std::endl;
    return -1;
  }

  std::cout << "Grid dimension: " << grid_dim[0] << "x" << grid_dim[1] << std::endl;
  std::cout << "Multicast group (X-axis cluster, shared A): " << mc_group << std::endl;
  std::cout << "Block dimension: " << block_dim[0] << "x" << block_dim[1] << std::endl;
  std::cout << "matrix A: " << M << "x" << K << std::endl;
  std::cout << "matrix B: " << K << "x" << N << std::endl;
  std::cout << "matrix C: " << M << "x" << N << std::endl;

  kernel_arg.M = M;
  kernel_arg.N = N;
  kernel_arg.K = K;
  kernel_arg.cta_M = cta_M;
  kernel_arg.mc_group_size = mc_group;

  std::cout << "allocate device memory" << std::endl;
  RT_CHECK(vx_buffer_create(device, sizeA * sizeof(itype_t), VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_buffer_address(A_buffer, &kernel_arg.A_addr));
  RT_CHECK(vx_buffer_create(device, sizeB * sizeof(itype_t), VX_MEM_READ, &B_buffer));
  RT_CHECK(vx_buffer_address(B_buffer, &kernel_arg.B_addr));
  RT_CHECK(vx_buffer_create(device, sizeC * sizeof(otype_t), VX_MEM_WRITE, &C_buffer));
  RT_CHECK(vx_buffer_address(C_buffer, &kernel_arg.C_addr));

  std::cout << "A_addr=0x" << std::hex << kernel_arg.A_addr << std::endl;
  std::cout << "B_addr=0x" << std::hex << kernel_arg.B_addr << std::endl;
  std::cout << "C_addr=0x" << std::hex << kernel_arg.C_addr << std::endl;

  std::vector<itype_t> h_A(sizeA);
  std::vector<itype_t> h_B(sizeB);
  for (uint32_t i = 0; i < sizeA; ++i) {
    h_A[i] = generate_A_value<vt::ITYPE>();
  }
  for (uint32_t i = 0; i < sizeB; ++i) {
    h_B[i] = generate_B_value<vt::ITYPE>();
  }

  {
    std::cout << "upload matrix A buffer" << std::endl;
    RT_CHECK(vx_enqueue_write(queue, A_buffer, 0, h_A.data(), sizeA * sizeof(itype_t), 0, nullptr, nullptr));
  }

  // h_B_col must outlive the async write below.
  std::vector<itype_t> h_B_col(sizeB);
  {
    std::cout << "upload matrix B buffer" << std::endl;
    if constexpr (vt::ITYPE::bits == 4) {
      // h_B is [KS][N] row-major with two nibbles per byte; repack to [N][KS].
      convert_row_to_col_major_4bit((uint8_t *)h_B_col.data(), N, 2 * K, (const uint8_t *)h_B.data());
    } else {
      convert_row_to_col_major(h_B_col.data(), h_B.data(), K, N);
    }
    RT_CHECK(vx_enqueue_write(queue, B_buffer, 0, h_B_col.data(), sizeB * sizeof(itype_t), 0, nullptr, nullptr));
  }

  // DXA descriptors describe the DRAM-side tiling; the kernel then issues one
  // copy per (k, tile) coordinate instead of a scalar staging loop.
  //
  // A is [M][K] row-major   -> dim0 = k, dim1 = row, tile = cta_M x tileK
  // B is [N][K] col-major   -> dim0 = k, dim1 = col, tile = tileN x tileK
  //   (no transpose: the kernel loads fragB col_major with ldm = tileK)
  RT_CHECK(vortex::dxa::program_2d(device, kDescA, kernel_arg.A_addr,
    /*size0=*/K, /*size1=*/M,
    /*stride0_bytes=*/K * sizeof(itype_t),
    /*tile0=*/cfg::tileK, /*tile1=*/cta_M,
    /*elem_bytes=*/sizeof(itype_t)));

  RT_CHECK(vortex::dxa::program_2d(device, kDescB, kernel_arg.B_addr,
    /*size0=*/K, /*size1=*/N,
    /*stride0_bytes=*/K * sizeof(itype_t),
    /*tile0=*/cfg::tileK, /*tile1=*/cfg::tileN,
    /*elem_bytes=*/sizeof(itype_t)));

  std::cout << "load kernel module" << std::endl;
  RT_CHECK(vx_module_load_file(device, kernel_file, &module_));
  RT_CHECK(vx_module_get_kernel(module_, "main", &kernel));

  uint32_t smem_size = (cta_M * cfg::tileK + cfg::tileK * cfg::tileN) * sizeof(itype_t);

  // Multicast scatter address = issuer_base + r * smem_stride, and the CTA
  // LMEM bases are spaced by the KMU's MEM_BLOCK_SIZE-aligned per-CTA size
  // (VX_kmu.sv aligned_lmem_size_r). The stride must match that spacing, not
  // the raw request, or receivers r>=1 are written at the wrong offset.
  const uint32_t kBlock = VX_CFG_MEM_BLOCK_SIZE;
  uint32_t smem_stride = (smem_size + kBlock - 1) & ~(kBlock - 1);

  // THIRD mandatory step for multicast, separate from program_2d and
  // cluster_dim: without it smem_stride is 0, every replay beat resolves to
  // the issuer's own base, and only cluster rank 0 receives data. Ranks 1..K-1
  // still get their barrier release, so this does not hang -- it silently
  // computes on uninitialized LMEM (exactly (K-1)/K of the output wrong).
  RT_CHECK(vortex::dxa::set_multicast(device, kDescA, smem_stride));

  // Host result buffer — must outlive the async read enqueued below.
  std::vector<otype_t> h_C(sizeC);

  auto time_start = std::chrono::high_resolution_clock::now();

  std::cout << "start device" << std::endl;
  vx_event_h launch_ev = nullptr;
  {
    vx_launch_info_t li = {};
    li.struct_size  = sizeof(li);
    li.kernel       = kernel;
    li.args_host    = &kernel_arg;
    li.args_size    = sizeof(kernel_arg);
    li.ndim         = 2;
    li.grid_dim[0]  = grid_dim[0];
    li.grid_dim[1]  = grid_dim[1];
    li.block_dim[0] = block_dim[0];
    li.block_dim[1] = block_dim[1];
    li.lmem_size    = smem_size;
    // MANDATORY. Without it cluster_size defaults to 1, get_cluster_rank()
    // (CTA_ID % cluster_size) is 0 for every CTA, and all mc_group CTAs fire
    // the multicast instead of just rank-0 -- each scattering to the full
    // mask and over-releasing receivers' local_A (which expects 1 tx). It is
    // also what makes VX_cta_dispatch reserve the cluster's LMEM contiguously,
    // which the scatter's `issuer + r * stride` addressing depends on.
    li.cluster_dim[0] = mc_group;   // X axis: same blockIdx.y => shared A tile
    li.cluster_dim[1] = 1;
    RT_CHECK(vx_enqueue_launch(queue, &li, 0, nullptr, &launch_ev));
  }

  std::cout << "download destination buffer" << std::endl;
  vx_event_h read_ev = nullptr;
  RT_CHECK(vx_enqueue_read(queue, h_C.data(), C_buffer, 0, sizeC * sizeof(otype_t), 1, &launch_ev, &read_ev));

  std::cout << "wait for completion" << std::endl;
  RT_CHECK(vx_event_wait_value(read_ev, 1, VX_TIMEOUT_INFINITE));
  vx_event_release(read_ev);
  vx_event_release(launch_ev);

  auto time_end = std::chrono::high_resolution_clock::now();
  double elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(time_end - time_start).count();
  printf("Elapsed time: %lg ms\n", elapsed);

  // matmul_cpu is a naive M*N*K triple loop, so verification costs the same
  // arithmetic the accelerator just did -- on the FLUX shapes (up to 2.2e11
  // MACs) that is hours per invocation on the host. SGEMM_SKIP_VERIFY=1 drops
  // it for timing sweeps ONLY; the device cycles reported above are unaffected.
  const bool skip_verify = (getenv("SGEMM_SKIP_VERIFY") != nullptr);
  int errors = 0;
  if (skip_verify) {
    std::cout << "verify result: SKIPPED (SGEMM_SKIP_VERIFY set) -- timing only" << std::endl;
  } else {
    std::cout << "verify result" << std::endl;
    std::vector<otype_t> h_ref(sizeC);
    matmul_cpu(h_ref.data(), h_A.data(), h_B.data(), M, N, K);

    for (uint32_t i = 0; i < h_ref.size(); ++i) {
      if (!Comparator<vt::OTYPE>::compare(h_C[i], h_ref[i], i, errors)) {
        ++errors;
      }
    }
  }

  std::cout << "cleanup" << std::endl;
  cleanup();

  if (errors != 0) {
    std::cout << "Found " << std::dec << errors << " / " << sizeC << " errors!" << std::endl;
    std::cout << "FAILED!" << std::endl;
    return errors;
  }

  std::cout << "PASSED!" << std::endl;

  return 0;
}
