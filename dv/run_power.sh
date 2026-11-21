#!/usr/bin/env bash
# Builds tb_power (Verilator, assertions on) and runs the directed test and
# the PLL-stuck test. The off-state model drives random values here; the X
# version runs on xsim (run_power_x.ps1).
#
#   BUILD_DIR  build root (default: build/dv in the repository)
#   PWR_RTL    RTL root to build from (default: rtl/; the mutation script points it at copies)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/power"
rtl="${PWR_RTL:-$root/rtl}"
mkdir -p "$out"

src=(
  "$here/lint/waivers.vlt"
  "$root/rtl/csr/gen/pmu_regs_pkg.sv" "$root/rtl/csr/gen/host_regs_pkg.sv"
  "$root/rtl/csr/gen/pmu_regs.sv" "$root/rtl/csr/gen/host_regs.sv"
  "$rtl/common/cdc_sync_2ff.sv" "$rtl/common/cdc_async_fifo.sv" "$rtl/common/rst_sync.sv"
  "$rtl/common/clk_gate.sv" "$rtl/pmu/iso_clamp.sv" "$rtl/pmu/ret_reg.sv" "$rtl/pmu/apb_cdc.sv"
  "$rtl/pmu/pmu.sv" "$rtl/host/phy_pll_model.sv" "$rtl/host/host_stub.sv" "$rtl/host/pd_host.sv"
  "$rtl/host/host_if.sv" "$rtl/top/soc_pwr.sv"
  "$here/tb/tb_power.sv"
)

verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_power \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && timeout 600 ./obj/Vtb_power "$@") > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[PWR\] .*: PASS' "$out/$name.log" || fail=1
  grep -E '^\[PWR\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -40
}

run directed  +test=directed +verilator+seed+1
run pll_stuck +test=pll_stuck +pll_stuck +verilator+seed+1

if [ "$fail" -eq 0 ]; then
  echo "[PWR] all runs PASS"
else
  echo "[PWR] FAIL"
  exit 1
fi
