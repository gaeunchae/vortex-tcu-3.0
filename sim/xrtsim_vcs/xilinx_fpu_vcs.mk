# Shared Xilinx floating-point IP setup for mixed-language VCS simulations.

XILINX_FPU_VCS_MK := $(lastword $(MAKEFILE_LIST))
XILINX_FPU_DESTDIR ?= $(DESTDIR)
XILINX_IP_DIR ?= $(XILINX_FPU_DESTDIR)/xilinx_ip
XILINX_DEVICE_PART ?= xcu55c-fsvh2892-2L-e
XILINX_IP_GEN_TCL ?= $(VORTEX_HOME)/hw/scripts/xilinx_ip_gen.tcl
XILINX_IP_STAMP ?= $(XILINX_IP_DIR)/.generated.stamp
XILINX_IP_VHDLAN_STAMP ?= $(XILINX_FPU_DESTDIR)/.xilinx_fpu_ip_vhdlan.stamp
XILINX_FPU_IPS := xil_fdiv xil_fsqrt xil_fma xil_fmul xil_fadd \
                  xil_f32add xil_f32mul xil_f16add xil_f16mul
XILINX_IP_VHDL_LIBS := xil_defaultlib xbip_utils_v3_0_14 axi_utils_v2_0_10 \
                       xbip_pipe_v3_0_10 xbip_dsp48_wrapper_v3_0_7 \
                       mult_gen_v12_0_23 floating_point_v7_1_20

SIMLIB_DIR ?= $(VORTEX_HOME)/build/vcs_simlib
SIMLIB_SETUP ?= $(SIMLIB_DIR)/synopsys_sim.setup
COMPILE_VCS_SIMLIB_TCL ?= $(VORTEX_HOME)/sim/xrtsim_vcs/compile_vcs_simlib.tcl
XILINX_FPU_VCS_LIB_FLAGS := +vhdllib+xil_defaultlib
XILINX_FPU_VHDLAN_FLAGS ?= -full64

XILINX_FPU_VCS_SETUP_CMD = mkdir -p $(XILINX_FPU_DESTDIR)/vcs_lib/work \
	$(foreach lib,$(XILINX_IP_VHDL_LIBS),$(XILINX_FPU_DESTDIR)/vcs_lib/$(lib)) && \
	{ echo "LIBRARY_SCAN=TRUE"; \
	  echo "work:$(abspath $(XILINX_FPU_DESTDIR))/vcs_lib/work"; \
	  $(foreach lib,$(XILINX_IP_VHDL_LIBS),echo "$(lib):$(abspath $(XILINX_FPU_DESTDIR))/vcs_lib/$(lib)";) \
	  echo "OTHERS=$(abspath $(SIMLIB_SETUP))"; \
	} > $(XILINX_FPU_DESTDIR)/synopsys_sim.setup

$(SIMLIB_SETUP):
	@mkdir -p "$(SIMLIB_DIR)" "$(XILINX_FPU_DESTDIR)"
	vivado -mode batch -nolog -nojournal -notrace \
		-source "$(COMPILE_VCS_SIMLIB_TCL)" \
		-tclargs "$(SIMLIB_DIR)" "$$(dirname $$(readlink -f $$(which vlogan)))" "" "0" "all" "all" \
		> "$(XILINX_FPU_DESTDIR)/compile_simlib.log" 2>&1 || { \
			echo "ERROR: compile_simlib failed. See $(XILINX_FPU_DESTDIR)/compile_simlib.log"; \
			exit 1; \
		}
	@test -f "$(SIMLIB_SETUP)" || { echo "ERROR: $(SIMLIB_SETUP) not found after compile_simlib."; exit 1; }

$(XILINX_IP_STAMP): $(XILINX_IP_GEN_TCL)
	@mkdir -p "$(XILINX_IP_DIR)" "$(XILINX_FPU_DESTDIR)"
	@missing=0; \
	for ip in $(XILINX_FPU_IPS); do \
		test -f "$(XILINX_IP_DIR)/$$ip/$$ip.xci" || missing=1; \
	done; \
	if [ $$missing -ne 0 ]; then \
		echo "INFO: generating Xilinx floating_point IP in $(XILINX_IP_DIR)"; \
		vivado -mode batch -nolog -nojournal -notrace \
			-source "$(XILINX_IP_GEN_TCL)" \
			-tclargs "$(XILINX_IP_DIR)" "$(XILINX_DEVICE_PART)" \
			> "$(XILINX_FPU_DESTDIR)/xilinx_ip_gen.log" 2>&1 || { \
				echo "ERROR: Xilinx IP generation failed. See $(XILINX_FPU_DESTDIR)/xilinx_ip_gen.log"; \
				exit 1; \
			}; \
	fi
	@touch $@

$(XILINX_IP_VHDLAN_STAMP): $(XILINX_IP_STAMP) $(SIMLIB_SETUP) $(XILINX_FPU_VCS_MK)
	@mkdir -p "$(XILINX_FPU_DESTDIR)"
	$(XILINX_FPU_VCS_SETUP_CMD)
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work xbip_utils_v3_0_14 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_utils_v3_0_vh_rfs.vhd" -l vhdlan_xbip_utils.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work axi_utils_v2_0_10 "$(XILINX_IP_DIR)/xil_fma/hdl/axi_utils_v2_0_vh_rfs.vhd" -l vhdlan_axi_utils.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work xbip_pipe_v3_0_10 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_pipe_v3_0_vh_rfs.vhd" -l vhdlan_xbip_pipe.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work xbip_dsp48_wrapper_v3_0_7 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_dsp48_wrapper_v3_0_vh_rfs.vhd" -l vhdlan_xbip_dsp48.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work mult_gen_v12_0_23 "$(XILINX_IP_DIR)/xil_fma/hdl/mult_gen_v12_0_vh_rfs.vhd" -l vhdlan_mult_gen.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work floating_point_v7_1_20 "$(XILINX_IP_DIR)/xil_fma/hdl/floating_point_v7_1_vh_rfs.vhd" -l vhdlan_floating_point.log
	cd $(XILINX_FPU_DESTDIR) && vhdlan $(XILINX_FPU_VHDLAN_FLAGS) -work xil_defaultlib $(foreach ip,$(XILINX_FPU_IPS),"$(XILINX_IP_DIR)/$(ip)/sim/$(ip).vhd") -l vhdlan_xilinx_wrappers.log
	@touch $@
