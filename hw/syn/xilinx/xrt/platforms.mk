# Platform specific configurations
# Add your platform specific configurations here

CONFIGS += -DPLATFORM_MEMORY_DATA_WIDTH=512

ifeq ($(DEV_ARCH), zynquplus)
# zynquplus
CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=32
else ifeq ($(DEV_ARCH), versal)
# versal
CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=32
ifneq ($(findstring xilinx_vck5000,$(XSA)),)
	CONFIGS += -DPLATFORM_MEMORY_OFFSET=40'hC000000000
endif
else
# alveo
# The Command Processor's host-memory master (m_axi_host) reaches host DRAM
# through the platform slave-bridge / Host Memory Access aperture. All Alveo
# XDMA shells expose this as the HOST[0] connectivity tag.
VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_host:HOST[0]
ifneq ($(findstring xilinx_u55c,$(XSA)),)
  # 16 GB of HBM2 with 32 channels (512 MB per channel)
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=32 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=34
  CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE
  # The 32 HBM banks are merged behind AXI_PORTS top-level AXI masters, with
  # 64 B blocks round-robined across them. AXI_PORTS=1 restores the old build.
  AXI_PORTS ?= 8
  CONFIGS += -DPLATFORM_MEMORY_MERGED_PORTS=$(AXI_PORTS)
  # VX_axi_adapter is a VX_MEM_PORTS x AXI_PORTS crossbar, so VX_MEM_PORTS — not
  # the master count — caps how many masters can be busy. On a single-core build
  # VX_MEM_PORTS follows the D-cache bank count through the bypassed L2/L3, so
  # widening the D-cache is what widens the whole path; keep it == AXI_PORTS.
  # DXA merges into the L2 arb alongside the socket ports, so it rides the same
  # VX_MEM_PORTS; but DXA_L2_GMEM_PORTS is capped by NUM_DXA_UNITS, which
  # defaults to 1 on a single-core build. Widen both or DXA keeps one port.
  MEM_PORTS ?= $(AXI_PORTS)
  CONFIGS += -DVX_CFG_DCACHE_NUM_BANKS=$(MEM_PORTS)
  CONFIGS += -DVX_CFG_NUM_DXA_UNITS=$(MEM_PORTS)
  # HBM aperture mapping, selected by BANK_CONTIGUOUS.
  #
  # 1 (default): master i owns HBM[i*K : i*K+K-1], K = 32/AXI_PORTS -- the
  #   layout fifusion-vortex@pe-with-int2 is HW-validated with. VX_mem_remap
  #   moves the master index into the top address bits, and BOTH masters that
  #   reach platform memory share that one module:
  #     * VX_axi_adapter  (cores' LSU/cache path)
  #     * VX_cp_axi_remap (Command Processor's DMA path)
  #   The CP one is load-bearing: VX_cp_core's device master is arb'd onto
  #   m_axi_mem_* and VX_cp_dma emits 64 B-beat INCR bursts, so without the
  #   remap+split it would write the kernel and the source buffers at identity
  #   addresses while the cores read them at the remapped ones -- agreeing only
  #   for bank 0. Verified under --driver=xrt_vcs (demo, 8 banks/8 masters).
  #
  # 0: flat layout -- VX_axi_adapter re-inserts the bank index at
  #   bit LOG2(BLOCK_SIZE), so the emitted address is the IDENTITY of the
  #   device address and every master must see the WHOLE aperture. Masters
  #   still run concurrently; the adapter's bank select spreads 64 B blocks
  #   across them. This is what upstream (and vortex_tc_extend@fpint_base) do.
  #
  # The `sp` ranges and the remap must stay in lockstep -- a mismatch sends
  # transactions outside a master's window with no compile-time complaint.
  # Nothing to slice with a single master, so AXI_PORTS=1 stays on the flat
  # layout and reproduces the original build exactly.
  ifeq ($(AXI_PORTS),1)
    BANK_CONTIGUOUS ?= 0
  else
    BANK_CONTIGUOUS ?= 1
  endif
  ifeq ($(BANK_CONTIGUOUS),1)
    CONFIGS += -DPLATFORM_MEMORY_BANK_CONTIGUOUS
    VPP_FLAGS += $(shell k=$$((32/$(AXI_PORTS))); for i in $$(seq 0 $$(($(AXI_PORTS)-1))); do \
        echo --connectivity.sp vortex_afu_1.m_axi_mem_$$i:HBM[$$((i*k)):$$((i*k+k-1))]; done)
  else
    VPP_FLAGS += $(shell for i in $$(seq 0 $$(($(AXI_PORTS)-1))); do \
        echo --connectivity.sp vortex_afu_1.m_axi_mem_$$i:HBM[0:31]; done)
  endif
else ifneq ($(findstring xilinx_u50,$(XSA)),)
  # 8 GB of HBM2 with 32 channels (256 MB per channel)
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=32 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=33
  CONFIGS += -DPLATFORM_MERGED_MEMORY_INTERFACE
  VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
else ifneq ($(findstring xilinx_u280,$(XSA)),)
  # 8 GB of HBM2 with 32 channels (256 MB per channel)
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=32 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=33
  VPP_FLAGS += --connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]
else ifneq ($(findstring xilinx_u250,$(XSA)),)
  # 64 GB of DDR4 with 4 channels (16 GB per channel)
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=4 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=36
else ifneq ($(findstring xilinx_u200,$(XSA)),)
  # 64 GB of DDR4 with 4 channels (16 GB per channel)
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=4 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=36
else
  CONFIGS += -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=32
endif
endif
