# Block-level checks: lint of rtl/ and the block testbenches.
#   make -C dv          lint, fifo and slice
#   make -C dv fifo     FIFO at six clock pairs (FIFO_SRC, MIN_EFF: see run_fifo.sh)
# BUILD_DIR defaults to build/dv in the repository.

BUILD_DIR ?= $(abspath ../build/dv)
export BUILD_DIR
RTL := ../rtl

.PHONY: all lint fifo slice

all: lint fifo slice

lint:
	verilator --lint-only -Wall --top-module cdc_async_fifo \
	  $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv
	verilator --lint-only -Wall --top-module axi_channel_reg_slice \
	  $(RTL)/axi/axi_channel_reg_slice.sv
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
