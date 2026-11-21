# Block-level checks: lint of rtl/ and the block testbenches.
#   make -C dv            lint, fifo, slice, xbar
#   make -C dv fifo       FIFO at six clock pairs (FIFO_SRC, MIN_EFF: see run_fifo.sh)
#   make -C dv xbar       crossbar: directed test and SEEDS random seeds (SEEDS, N: see run_xbar.sh)
#   make -C dv xbar-mut   crossbar testbench against seven planted bugs (not part of all)
# BUILD_DIR defaults to build/dv in the repository.

BUILD_DIR ?= $(abspath ../build/dv)
export BUILD_DIR
RTL := ../rtl

XBAR_RTL := $(RTL)/common/rr_arb.sv $(RTL)/common/fifo_sync.sv \
            $(RTL)/axi/axi_id_tracker.sv $(RTL)/axi/axi_err_slv.sv $(RTL)/axi/axi_xbar.sv

.PHONY: all lint fifo slice xbar xbar-mut

all: lint fifo slice xbar

lint:
	verilator --lint-only -Wall --top-module cdc_async_fifo \
	  $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv
	verilator --lint-only -Wall --top-module axi_channel_reg_slice \
	  $(RTL)/axi/axi_channel_reg_slice.sv
	verilator --lint-only -Wall --top-module axi_xbar $(XBAR_RTL)
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
