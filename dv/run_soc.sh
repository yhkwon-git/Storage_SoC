#!/usr/bin/env bash
# Builds the firmware (when the cross compiler is on PATH; otherwise the
# committed fw/images are used), builds tb_soc once and runs every firmware
# test twice: alone and with background traffic from the host model through
# the transaction layer on M3 (M2 is the DMA). The
# reset test runs alone only: its chip reset would abandon the host model's
# outstanding reads and its enumeration. Then the NVMe host driver model runs
# against nvme_app (+test=nvme_rand, step 2-5): NVME_RAND_SEEDS seeds of
# NVME_RAND_N commands, seed 1 also with background traffic, and every bin of
# its covergroups must be hit.
#
#   NVME_RAND_SEEDS  seeds of nvme_rand (default 3)
#   NVME_RAND_N      I/O commands per nvme_rand run (default 1200)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/soc"
tests=(hello memtest irq buserr perf dma power reset host nvme soc_app nvme_app)
mkdir -p "$out"

if command -v riscv-none-elf-gcc > /dev/null; then
  make -s -C "$root/fw" BUILD="$out/fw" > "$out/fw_build.log" 2>&1 || { cat "$out/fw_build.log"; exit 1; }
  img="$out/fw"
  for t in "${tests[@]}"; do
    if ! cmp -s "$img/$t.hex" "$root/fw/images/$t.hex"; then
      echo "[SOC] note: fw/images/$t.hex differs from a fresh build (run make -C fw images)"
    fi
  done
else
  img="$root/fw/images"
  echo "[SOC] riscv-none-elf-gcc not found; using the committed images in fw/images"
fi

rtl="$root/rtl"
src=(
  "$here/lint/waivers.vlt" -F "$rtl/vendor/ibex/ibex.f"
  "$rtl/csr/gen/sys_regs_pkg.sv" "$rtl/csr/gen/intc_regs_pkg.sv" "$rtl/csr/gen/timer_regs_pkg.sv"
  "$rtl/csr/gen/dma_regs_pkg.sv" "$rtl/csr/gen/pmu_regs_pkg.sv" "$rtl/csr/gen/host_regs_pkg.sv"
  "$rtl/csr/gen/nvme_regs_pkg.sv"
  "$rtl/csr/gen/sys_regs.sv" "$rtl/csr/gen/intc_regs.sv" "$rtl/csr/gen/timer_regs.sv"
  "$rtl/csr/gen/dma_regs.sv" "$rtl/csr/gen/pmu_regs.sv" "$rtl/csr/gen/host_regs.sv"
  "$rtl/csr/gen/nvme_regs.sv"
  "$rtl/common/rr_arb.sv" "$rtl/common/fifo_sync.sv" "$rtl/common/cdc_sync_2ff.sv"
  "$rtl/common/cdc_async_fifo.sv" "$rtl/common/rst_sync.sv" "$rtl/common/clk_gate.sv"
  "$rtl/axi/axi_id_tracker.sv" "$rtl/axi/axi_err_slv.sv" "$rtl/axi/axi_xbar.sv" "$rtl/axi/axi2apb.sv"
  "$rtl/cpu/cpu_ibex.sv" "$rtl/cpu/obi2axi.sv" "$rtl/mem/mem_array.sv" "$rtl/mem/axi_mem.sv"
  "$rtl/periph/apb_sys.sv" "$rtl/periph/apb_timer.sv" "$rtl/periph/apb_intc.sv"
  "$rtl/dma/dma.sv" "$rtl/axi/axi_channel_reg_slice.sv"
  "$rtl/host/tl/tl_pkg.sv" "$rtl/host/tl/tl_dw_align.sv" "$rtl/host/tl/tl_rx_buf.sv"
  "$rtl/host/tl/tl_rx_unpack.sv" "$rtl/host/tl/tl_tx_pack.sv" "$rtl/host/tl/tl_cfg.sv" "$rtl/host/tl/tl_msix.sv"
  "$rtl/host/tl/tl_wr.sv" "$rtl/host/tl/tl_rd.sv" "$rtl/host/tl/tl_bm.sv" "$rtl/host/tl/tl_core.sv"
  "$rtl/host/tl/tl_port.sv" "$rtl/host/nvme/nvme_lbuf.sv" "$rtl/host/nvme/nvme_prp.sv" "$rtl/host/nvme/nvme_cqe.sv"
  "$rtl/host/nvme/nvme_ctrl.sv" "$here/sva/nvme_checker.sv" "$here/sva/nvme_bind.sv"
  "$rtl/pmu/iso_clamp.sv" "$rtl/pmu/ret_reg.sv" "$rtl/pmu/apb_cdc.sv" "$rtl/pmu/pmu.sv"
  "$rtl/host/phy_pll_model.sv" "$rtl/host/host_stub.sv" "$rtl/host/pd_host.sv" "$rtl/host/host_if.sv"
  "$rtl/top/soc_pwr.sv" "$rtl/top/soc_top.sv"
  "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/nvme_host_pkg.sv"
  "$here/tb/tb_soc.sv"
)

verilator --binary --timing --assert --coverage-user -j 0 --timescale 1ns/1ps --top-module tb_soc \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

fail=0
for t in "${tests[@]}"; do
  modes=("" "+bg")
  [ "$t" = reset ] && modes=("")
  for mode in "${modes[@]}"; do
    name="$t${mode:+_bg}"
    extra=""
    [ "$t" = hello ] && extra="+apb_check"
    # shellcheck disable=SC2086
    if ! (cd "$out" && ./obj/Vtb_soc +rom="$img/$t.hex" +test="$t" $mode $extra +verilator+seed+1) \
         > "$out/$name.log" 2>&1; then
      fail=1
    fi
    grep -E '^\[(FW|SOC)\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /"
  done
done

rand_seeds="${NVME_RAND_SEEDS:-3}"
rand_n="${NVME_RAND_N:-1200}"
rm -f "$out"/cov_nvme_rand*.dat
for s in $(seq 1 "$rand_seeds"); do
  for mode in "" "+bg"; do
    if [ -n "$mode" ] && [ "$s" -ne 1 ]; then continue; fi
    name="nvme_rand$s${mode:+_bg}"
    # shellcheck disable=SC2086
    if ! (cd "$out" && ./obj/Vtb_soc +rom="$img/nvme_app.hex" +test=nvme_rand +nvme_n="$rand_n" $mode             +verilator+seed+"$s" +verilator+coverage+file+"cov_$name.dat") > "$out/$name.log" 2>&1; then
      fail=1
    fi
    grep -E '^\[(FW|SOC|NVMEH)\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /"
  done
done
verilator_coverage --write "$out/merged.dat" "$out"/cov_nvme_rand*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[SOC] nvme_rand covergroup bins hit: $hit of $bins"
if [ "$bins" -eq 0 ] || [ "$hit" -ne "$bins" ]; then
  grep 't.covergroup' "$out/merged.dat" | awk '$NF == 0' | sed 's/^/[SOC] not hit: /' | cut -c1-160
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "[SOC] all runs PASS"
else
  echo "[SOC] FAIL"
  exit 1
fi
