# Block-level checks: lint of rtl/ and the block testbenches.
#   make -C dv            lint, fifo, slice, xbar, soc
#   make -C dv fifo       FIFO at six clock pairs (FIFO_SRC, MIN_EFF: see run_fifo.sh)
#   make -C dv xbar       crossbar: directed test and SEEDS random seeds (SEEDS, N: see run_xbar.sh)
#   make -C dv xbar-mut   crossbar testbench against seven planted bugs (not part of all)
#   make -C dv soc        firmware tests on soc_top, alone and with background traffic
#   make -C dv ral        UVM register tests on Vivado's simulator (Windows, through WSL interop;
#                         not part of all: the CI image has no Vivado)
#   make -C dv ral-mut    register tests against four planted bugs (Vivado, not part of all)
#   make -C dv rdl-check  generated register files still match rtl/csr/rdl/soc_apb.rdl
#                         (needs PeakRDL, flow/rdl/requirements.txt; PEAKRDL=<path> if not on PATH)
# BUILD_DIR defaults to build/dv in the repository.

BUILD_DIR ?= $(abspath ../build/dv)
export BUILD_DIR
RTL := ../rtl

XBAR_RTL := $(RTL)/common/rr_arb.sv $(RTL)/common/fifo_sync.sv \
            $(RTL)/axi/axi_id_tracker.sv $(RTL)/axi/axi_err_slv.sv $(RTL)/axi/axi_xbar.sv
CSR_GEN  := $(RTL)/csr/gen/sys_regs_pkg.sv $(RTL)/csr/gen/intc_regs_pkg.sv $(RTL)/csr/gen/timer_regs_pkg.sv \
            $(RTL)/csr/gen/sys_regs.sv $(RTL)/csr/gen/intc_regs.sv $(RTL)/csr/gen/timer_regs.sv
SOC_RTL  := $(CSR_GEN) $(XBAR_RTL) $(RTL)/axi/axi2apb.sv $(RTL)/cpu/cpu_ibex.sv $(RTL)/cpu/obi2axi.sv \
            $(RTL)/mem/axi_mem.sv $(RTL)/periph/apb_sys.sv $(RTL)/periph/apb_timer.sv \
            $(RTL)/periph/apb_intc.sv $(RTL)/top/soc_top.sv

.PHONY: all lint fifo slice xbar xbar-mut soc ral ral-mut rdl-check

all: lint fifo slice xbar soc

lint:
	verilator --lint-only -Wall --top-module cdc_async_fifo \
	  $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv
	verilator --lint-only -Wall --top-module axi_channel_reg_slice \
	  $(RTL)/axi/axi_channel_reg_slice.sv
	verilator --lint-only -Wall --top-module axi_xbar $(XBAR_RTL)
	verilator --lint-only -Wall --timescale 1ns/1ps --top-module soc_top \
	  lint/waivers.vlt -F $(RTL)/vendor/ibex/ibex.f $(SOC_RTL)
	@echo "[LINT] PASS"

fifo:
	bash run_fifo.sh

slice:
	mkdir -p $(BUILD_DIR)/slice
	verilator --binary --timing -j 0 --top-module tb_axi_channel_reg_slice \
	  $(RTL)/axi/axi_channel_reg_slice.sv tb/tb_axi_channel_reg_slice.sv \
	  -Mdir $(BUILD_DIR)/slice/obj > $(BUILD_DIR)/slice/build.log 2>&1 \
	  || (cat $(BUILD_DIR)/slice/build.log; exit 1)
	$(BUILD_DIR)/slice/obj/Vtb_axi_channel_reg_slice +verilator+seed+7 | grep '^\[SLICE\]'

xbar:
	bash run_xbar.sh

xbar-mut:
	bash mutate_xbar.sh

soc:
	bash run_soc.sh

ral:
	powershell.exe -ExecutionPolicy Bypass -File "$$(wslpath -w run_ral.ps1)"

ral-mut:
	powershell.exe -ExecutionPolicy Bypass -File "$$(wslpath -w mutate_ral.ps1)"

rdl-check:
	bash ../flow/rdl/gen.sh --check
