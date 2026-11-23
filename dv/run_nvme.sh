#!/usr/bin/env bash
# Builds tb_nvme once (with assertions and coverage), runs the directed tests
# and the throughput test (perf), then the random test for seeds 1..SEEDS. Fails unless every run passes and
# every covergroup bin is hit.
#
#   SEEDS      random seeds to run (default 10)
#   NVME_N     commands per random run (default 2000)
#   NVME_RTL   RTL root (default: rtl in the repository; dv/mutate_nvme.sh
#              points it at a mutated copy)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/nvme"
seeds="${SEEDS:-10}"
n="${NVME_N:-2000}"
mkdir -p "$out"

rtl="${NVME_RTL:-$root/rtl}"
t="$root/rtl/host/tl"
src=(
  "$here/lint/waivers.vlt"
  "$root/rtl/common/fifo_sync.sv" "$root/rtl/axi/axi_channel_reg_slice.sv"
  "$t/tl_pkg.sv" "$t/tl_dw_align.sv" "$t/tl_rx_buf.sv" "$t/tl_rx_unpack.sv" "$t/tl_tx_pack.sv"
  "$t/tl_cfg.sv" "$t/tl_msix.sv" "$t/tl_wr.sv" "$t/tl_rd.sv" "$t/tl_bm.sv" "$t/tl_core.sv"
  "$root/rtl/csr/gen/nvme_regs_pkg.sv" "$root/rtl/csr/gen/nvme_regs.sv" "$rtl/host/nvme/nvme_ctrl.sv"
  "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv"
  "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/tb_nvme.sv"
)

verilator --binary --timing --assert --coverage -j 0 --timescale 1ns/1ps --top-module tb_nvme \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && timeout 1800 ./obj/Vtb_nvme "$@" +verilator+coverage+file+"cov_$name.dat") \
       > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[NVME\] PASS' "$out/$name.log" || fail=1
  grep -E '^\[NVME\]|^\[HOST\]|^\[DMA\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -60
}

for t in regs enable fetch rr doorbell ferr shutdown reset perf; do
  run "$t" +test="$t" +verilator+seed+1
done
for s in $(seq 1 "$seeds"); do
  run "seed$s" +test=random +n="$n" +verilator+seed+"$s" | grep -E 'random:|ERROR|FAIL|%Error|Assertion' || true
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[NVME] covergroup bins hit: $hit of $bins"
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/host/nvme/

if [ "$fail" -eq 0 ] && [ "$hit" -eq "$bins" ]; then
  echo "[NVME] PASS"
else
  echo "[NVME] FAIL"
  exit 1
fi
