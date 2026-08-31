include ../common.mk

DESTDIR ?= $(CURDIR)

CONFIG_FILE := $(DESTDIR)/xrtsim_vcs_config.stamp
SRC_DIR := $(VORTEX_HOME)/sim/xrtsim_vcs
XRTSIM_DIR := $(VORTEX_HOME)/sim/xrtsim
AFU_DIR := $(RTL_DIR)/afu/xrt

# ============================================================================
# Host-side device model (libxrtsim_vcs.so)
#
# Exposes the same vortex::xrt_sim class as sim/xrtsim, so sw/runtime/xrt links
# against either without source changes. The difference is the backend: xrtsim
# drives a Verilated DUT in-process, this one drives a VCS simv over two TCP
# sockets (ctrl for AXI-Lite, mem for the AXI masters).
# ============================================================================

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors -Wno-array-bounds
CXXFLAGS += -fPIC -Wno-maybe-uninitialized
CXXFLAGS += -I$(SRC_DIR) -I$(XRTSIM_DIR) -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(SIM_COMMON_DIR) -I$(SW_COMMON_DIR) -I$(DESTDIR)
CXXFLAGS += -I/$(THIRD_PARTY_DIR)/softfloat/source/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/spdlog/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/yaml-cpp/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/src
CXXFLAGS += -DVX_CFG_XLEN=$(XLEN) -DVX_CFG_XLEN_$(XLEN)
CXXFLAGS += -DNOXRT
CXXFLAGS += $(CONFIGS)

LDFLAGS += -shared $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
LDFLAGS += -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator -L$(THIRD_PARTY_DIR)/ramulator -lramulator -pthread

APP_SRCS = $(SW_COMMON_DIR)/util.cpp $(SIM_COMMON_DIR)/mem.cpp
APP_SRCS += $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp
APP_SRCS += $(SIM_COMMON_DIR)/dram_sim.cpp
APP_SRCS += $(XRTSIM_DIR)/xrt_c.cpp
APP_SRCS += $(SRC_DIR)/xrt_sim_vcs.cpp

APP_PROJECT := libxrtsim_vcs.so

CONFIGS += -DSIMULATION -DSV_DPI

XCONFIGS := $(shell python3 $(ROOT_DIR)/ci/gen_config.py --config=$(VORTEX_HOME)/VX_config.toml --cflags='$(CONFIGS) -DVX_CFG_XLEN=$(XLEN)')

# ============================================================================
# RTL source list — kept in lockstep with sim/xrtsim/Makefile, which is the
# reference for what this tree's AFU needs to elaborate.
# ============================================================================

RTL_PKGS += $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv

FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(filter -DVX_CFG_FPU_TYPE_FPNEW, $(XCONFIGS)))
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_pkg.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
	FPU_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src -I$(THIRD_PARTY_DIR)/cvfpu/src
	FPU_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/stubs
endif

RTL_INCLUDE = -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(SRC_DIR) -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache $(FPU_INCLUDE)
RTL_INCLUDE += -I$(AFU_DIR)
RTL_INCLUDE += -I$(RTL_DIR)/cp

ifneq (,$(filter -DVX_CFG_EXT_TCU_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/tcu/VX_tcu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/tcu
	ifneq (,$(filter -DVX_CFG_TCU_TYPE_DPI, $(XCONFIGS)))
		RTL_INCLUDE += -I$(RTL_DIR)/tcu/dpi
	else ifneq (,$(filter -DVX_CFG_TCU_TYPE_DSP, $(XCONFIGS)))
		RTL_INCLUDE += -I$(RTL_DIR)/tcu/dsp
	else ifneq (,$(filter -DVX_CFG_TCU_TYPE_BHF, $(XCONFIGS)))
		RTL_INCLUDE += -I$(RTL_DIR)/tcu/bhf
		RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/hardfloat/source/RISCV
		RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/hardfloat/source
	else ifneq (,$(filter -DVX_CFG_TCU_TYPE_TFR, $(XCONFIGS)))
		RTL_INCLUDE += -I$(RTL_DIR)/tcu/tfr
	else
		RTL_INCLUDE += -I$(RTL_DIR)/tcu/dpi
	endif
endif

ifneq (,$(filter -DVX_CFG_EXT_DXA_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/dxa/VX_dxa_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/dxa
endif

ifneq (,$(filter -DVX_CFG_EXT_TEX_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/tex/VX_tex_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/tex
endif

ifneq (,$(filter -DVX_CFG_EXT_RASTER_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/raster/VX_raster_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/raster
endif

ifneq (,$(filter -DVX_CFG_EXT_OM_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/om/VX_om_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/om
endif

ifneq (,$(filter -DVX_CFG_EXT_V_ENABLE, $(XCONFIGS)))
	RTL_PKGS += $(RTL_DIR)/vpu/VX_vpu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/vpu
endif

RTL_PKGS += $(RTL_DIR)/VX_trace_pkg.sv
RTL_PKGS += $(RTL_DIR)/cp/VX_cp_pkg.sv

RTL_DIRS := $(patsubst -I%,%,$(filter -I%,$(RTL_INCLUDE)))
RTL_SRCS := $(shell find $(RTL_DIRS) -type f \( -name '*.v' -o -name '*.vh' -o -name '*.sv' \) 2>/dev/null)

TOP = tb_vcs_xrtsim

# ============================================================================
# VCS
# ============================================================================

VCS ?= vcs
VCS_DEFINES := $(patsubst -D%,+define+%,$(filter -D%,$(CONFIGS)))
VCS_DEFINES += +define+VX_CFG_XLEN=$(XLEN) +define+VX_CFG_XLEN_$(XLEN)

VCS_FLAGS += -full64 -sverilog +v2k -timescale=1ns/1ps
VCS_FLAGS += +lint=TFIPC-L
VCS_FLAGS += $(foreach d,$(RTL_DIRS),+incdir+$(d))
VCS_FLAGS += $(foreach d,$(RTL_DIRS),-y $(d)) +libext+.v+.sv
VCS_FLAGS += $(VCS_DEFINES)

# The DPI socket server and the RTL's DPI helpers are compiled into simv.
VCS_CPPFLAGS := -std=c++17 -I$(SRC_DIR) -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR) -I$(DPI_DIR)
VCS_CPPFLAGS += -I/$(THIRD_PARTY_DIR)/softfloat/source/include
VCS_CPPFLAGS += -DVX_CFG_XLEN=$(XLEN) -DVX_CFG_XLEN_$(XLEN)
VCS_FLAGS += -CFLAGS "$(VCS_CPPFLAGS)"

VCS_SRCS := $(SRC_DIR)/dpi_vcs_server.cpp $(DPI_DIR)/dpi_util.cpp $(DPI_DIR)/dpi_float.cpp
VCS_SRCS += $(SW_COMMON_DIR)/util.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp
SOFTFLOAT_A := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
# VCS emits LDFLAGS *before* $(OBJS) on its link line and filters out -Wl,
# options, so a static archive can neither be placed after the objects nor kept
# with --whole-archive. A shared library is not subject to the archive ordering
# rule, so wrap softfloat in one.
SOFTFLOAT_SO := $(DESTDIR)/lib/libsoftfloat.so
# --no-as-needed because the library lands before the objects that reference it,
# and ld would otherwise record it as unneeded and drop it.
VCS_LDFLAGS := -LDFLAGS "-L$(DESTDIR)/lib -Wl,--no-as-needed -lsoftfloat -Wl,-rpath,$(DESTDIR)/lib"
VCS_LD_ENV := LDFLAGS=

# Debug tracing. simv.log grows to multiple GB with tracing on; NO_DBG_TRACE=1
# keeps a functional debug build without the per-cycle dump.
DBG_TRACE_FLAGS += +define+DBG_TRACE_PIPELINE +define+DBG_TRACE_MEM
DBG_TRACE_FLAGS += +define+DBG_TRACE_CACHE +define+DBG_TRACE_AFU
DBG_TRACE_FLAGS += +define+DBG_TRACE_GBAR +define+DBG_TRACE_TCU

ifdef DEBUG
	VCS_FLAGS += -debug_access+all +define+VX_DBG_DEBUG_LEVEL=$(DEBUG)
ifndef NO_DBG_TRACE
	VCS_FLAGS += $(DBG_TRACE_FLAGS)
endif
else
	VCS_FLAGS += +define+NDEBUG
endif

ifdef PERF
	VCS_FLAGS += +define+PERF_ENABLE
	CXXFLAGS += -DPERF_ENABLE
endif

# FSDB waveform dump. Unlike a plain define, this pulls in the Verdi PLI and
# forces a -debug_access+all build, which is far slower — so it is opt-in by
# presence, not by value (FSDB_DUMP=0 would still enable it).
ifdef FSDB_DUMP
	VCS_FLAGS += +define+FSDB_DUMP -kdb -debug_access+all
ifdef VERDI_HOME
	VCS_FLAGS += -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
endif
endif

# X-propagation. Needs the XProp runtime feature in the license pool.
ifdef XPROP
	VCS_FLAGS += -xprop=tmerge
endif

.PHONY: all applib simv force clean

all: applib simv

applib: $(DESTDIR)/$(APP_PROJECT)

simv: $(DESTDIR)/simv

$(DESTDIR)/$(APP_PROJECT): $(APP_SRCS) $(CONFIG_FILE)
	$(CXX) $(CXXFLAGS) $(APP_SRCS) $(LDFLAGS) -o $@

# RTL_SRCS and CONFIG_FILE are real dependencies here: without them an RTL or
# CONFIGS change silently reuses the previous simv.
$(SOFTFLOAT_SO): $(SOFTFLOAT_A)
	@mkdir -p $(@D)
	$(CXX) -shared -o $@ -Wl,--whole-archive $(SOFTFLOAT_A) -Wl,--no-whole-archive

$(DESTDIR)/simv: $(SRC_DIR)/tb_vcs_xrtsim.sv $(VCS_SRCS) $(RTL_PKGS) $(RTL_SRCS) $(CONFIG_FILE) $(SOFTFLOAT_SO)
	@mkdir -p $(DESTDIR)
	cd $(DESTDIR) && $(VCS_LD_ENV) $(VCS) $(VCS_FLAGS) -top $(TOP) \
	  $(RTL_PKGS) $(SRC_DIR)/tb_vcs_xrtsim.sv $(VCS_SRCS) $(VCS_LDFLAGS) \
	  -o $@ -l compile.log

# Rebuild from scratch when the flag set changes.
$(CONFIG_FILE): force
	@mkdir -p $(@D)
	@printf '%s\n' "$(VCS_FLAGS)" "$(CXXFLAGS)" > $@.tmp
	@if ! cmp -s $@.tmp $@; then \
	  mv $@.tmp $@; \
	  rm -rf $(DESTDIR)/simv $(DESTDIR)/simv.daidir $(DESTDIR)/csrc; \
	else \
	  rm $@.tmp; \
	fi

clean:
	rm -rf $(DESTDIR)/simv $(DESTDIR)/simv.daidir $(DESTDIR)/csrc
	rm -rf $(DESTDIR)/$(APP_PROJECT) $(CONFIG_FILE)
	rm -f $(DESTDIR)/compile.log $(DESTDIR)/simv.log $(DESTDIR)/ucli.key
