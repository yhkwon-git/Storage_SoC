# Block-level checks: lint of rtl/ and the block testbenches.
#   make -C dv            lint, fifo, slice, xbar, dma, tl, nvme, power, soc
#   make -C dv fifo       FIFO at six clock pairs (FIFO_SRC, MIN_EFF: see run_fifo.sh)
#   make -C dv xbar       crossbar: directed test and SEEDS random seeds (SEEDS, N: see run_xbar.sh)
#   make -C dv xbar-mut   crossbar testbench against seven planted bugs (not part of all)
#   make -C dv dma        DMA: directed test and SEEDS random seeds (SEEDS, DMA_N: see run_dma.sh)
#   make -C dv dma-mut    DMA testbench against ten planted bugs (not part of all)
#   make -C dv tl         transaction layer: six directed tests, throughput, SEEDS random seeds (SEEDS, TL_N:
#                         see run_tl.sh)
#   make -C dv tl-mut     transaction-layer testbench against planted bugs (not part of all)
#   make -C dv nvme       NVMe controller: directed tests, SEEDS random queue and random I/O seeds
#                         (SEEDS, NVME_N, NVME_IO_N: see run_nvme.sh)
#   make -C dv nvme-mut   NVMe testbench against 27 planted bugs (not part of all)
#   make -C dv power      PMU, PD_HOST and resets: directed and PLL-stuck tests, random off-state values
#   make -C dv power-x    the same on Vivado's simulator with X off-state values (Windows, not part of all)
#   make -C dv power-mut  power testbench against eleven planted bugs (not part of all)
#   make -C dv iso-check  isolation and retention in the RTL match syn/upf/storage_soc.upf
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
            $(RTL)/csr/gen/dma_regs_pkg.sv $(RTL)/csr/gen/pmu_regs_pkg.sv $(RTL)/csr/gen/host_regs_pkg.sv \
            $(RTL)/csr/gen/nvme_regs_pkg.sv \
            $(RTL)/csr/gen/sys_regs.sv $(RTL)/csr/gen/intc_regs.sv $(RTL)/csr/gen/timer_regs.sv \
            $(RTL)/csr/gen/dma_regs.sv $(RTL)/csr/gen/pmu_regs.sv $(RTL)/csr/gen/host_regs.sv \
            $(RTL)/csr/gen/nvme_regs.sv
DMA_RTL  := $(RTL)/csr/gen/dma_regs_pkg.sv $(RTL)/csr/gen/dma_regs.sv $(RTL)/common/fifo_sync.sv \
            $(RTL)/dma/dma.sv
TL_RTL   := $(RTL)/axi/axi_channel_reg_slice.sv $(RTL)/host/tl/tl_pkg.sv $(RTL)/host/tl/tl_dw_align.sv \
            $(RTL)/host/tl/tl_rx_buf.sv $(RTL)/host/tl/tl_rx_unpack.sv $(RTL)/host/tl/tl_tx_pack.sv \
            $(RTL)/host/tl/tl_cfg.sv $(RTL)/host/tl/tl_msix.sv $(RTL)/host/tl/tl_wr.sv $(RTL)/host/tl/tl_rd.sv \
            $(RTL)/host/tl/tl_bm.sv $(RTL)/host/tl/tl_core.sv $(RTL)/host/tl/tl_port.sv
NVME_RTL := $(RTL)/csr/gen/nvme_regs_pkg.sv $(RTL)/csr/gen/nvme_regs.sv $(RTL)/host/nvme/nvme_lbuf.sv \
            $(RTL)/host/nvme/nvme_prp.sv $(RTL)/host/nvme/nvme_cqe.sv $(RTL)/host/nvme/nvme_ctrl.sv
PWR_RTL  := $(RTL)/csr/gen/pmu_regs_pkg.sv $(RTL)/csr/gen/host_regs_pkg.sv \
            $(RTL)/csr/gen/pmu_regs.sv $(RTL)/csr/gen/host_regs.sv $(RTL)/common/fifo_sync.sv $(TL_RTL) \
            $(NVME_RTL) \
            $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv $(RTL)/common/rst_sync.sv \
            $(RTL)/common/clk_gate.sv $(RTL)/pmu/iso_clamp.sv $(RTL)/pmu/ret_reg.sv $(RTL)/pmu/apb_cdc.sv \
            $(RTL)/pmu/pmu.sv $(RTL)/host/phy_pll_model.sv $(RTL)/host/host_stub.sv $(RTL)/host/pd_host.sv \
            $(RTL)/host/host_if.sv $(RTL)/top/soc_pwr.sv
SOC_RTL  := $(CSR_GEN) $(XBAR_RTL) $(RTL)/axi/axi2apb.sv $(RTL)/cpu/cpu_ibex.sv $(RTL)/cpu/obi2axi.sv \
            $(RTL)/mem/mem_array.sv $(RTL)/mem/axi_mem.sv $(RTL)/periph/apb_sys.sv $(RTL)/periph/apb_timer.sv \
            $(RTL)/periph/apb_intc.sv $(RTL)/dma/dma.sv $(TL_RTL) $(RTL)/host/nvme/nvme_lbuf.sv \
            $(RTL)/host/nvme/nvme_prp.sv $(RTL)/host/nvme/nvme_cqe.sv $(RTL)/host/nvme/nvme_ctrl.sv \
            $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv $(RTL)/common/rst_sync.sv \
            $(RTL)/common/clk_gate.sv $(RTL)/pmu/iso_clamp.sv $(RTL)/pmu/ret_reg.sv $(RTL)/pmu/apb_cdc.sv \
            $(RTL)/pmu/pmu.sv $(RTL)/host/phy_pll_model.sv $(RTL)/host/host_stub.sv $(RTL)/host/pd_host.sv \
            $(RTL)/host/host_if.sv $(RTL)/top/soc_pwr.sv $(RTL)/top/soc_top.sv

.PHONY: all lint fifo slice xbar xbar-mut dma dma-mut tl tl-mut nvme nvme-mut power power-x power-mut iso-check soc \
        ral ral-mut rdl-check

all: lint iso-check fifo slice xbar dma tl nvme power soc

lint:
	verilator --lint-only -Wall --top-module cdc_async_fifo \
	  $(RTL)/common/cdc_sync_2ff.sv $(RTL)/common/cdc_async_fifo.sv
	verilator --lint-only -Wall --top-module axi_channel_reg_slice \
	  $(RTL)/axi/axi_channel_reg_slice.sv
	verilator --lint-only -Wall --top-module axi_xbar $(XBAR_RTL)
	verilator --lint-only -Wall --timescale 1ns/1ps --top-module dma lint/waivers.vlt $(DMA_RTL)
	verilator --lint-only -Wall --timescale 1ns/1ps --top-module tl_core lint/waivers.vlt \
	  $(RTL)/common/fifo_sync.sv $(TL_RTL)
	verilator --lint-only -Wall --timescale 1ns/1ps --top-module nvme_ctrl lint/waivers.vlt $(NVME_RTL)
	verilator --lint-only -Wall --timescale 1ns/1ps --top-module soc_pwr lint/waivers.vlt $(PWR_RTL)
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

dma:
	bash run_dma.sh

dma-mut:
	bash mutate_dma.sh

tl:
	bash run_tl.sh

tl-mut:
	bash mutate_tl.sh

nvme:
	bash run_nvme.sh

nvme-mut:
	bash mutate_nvme.sh

power:
	bash run_power.sh

power-x:
	powershell.exe -ExecutionPolicy Bypass -File "$$(wslpath -w run_power_x.ps1)"

power-mut:
	bash mutate_power.sh

iso-check:
	python3 ../flow/power/check_iso.py

soc:
	bash run_soc.sh

ral:
	powershell.exe -ExecutionPolicy Bypass -File "$$(wslpath -w run_ral.ps1)"

ral-mut:
	powershell.exe -ExecutionPolicy Bypass -File "$$(wslpath -w mutate_ral.ps1)"

rdl-check:
	bash ../flow/rdl/gen.sh --check
