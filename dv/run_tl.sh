#!/usr/bin/env bash
# Builds tb_tl once (with assertions and coverage), runs the six directed
# tests and the throughput test (perf), then the random test for seeds
# 1..SEEDS. Fails unless every run passes and every covergroup bin is hit.
#
#   SEEDS      random seeds to run (default 10)
#   TL_N       operations per random run (default 3000)
#   TL_RTL     RTL root (default: rtl in the repository; dv/mutate_tl.sh
#              points it at a mutated copy)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/tl"
seeds="${SEEDS:-10}"
n="${TL_N:-3000}"
mkdir -p "$out"

rtl="${TL_RTL:-$root/rtl}"
t="$rtl/host/tl"
src=(
  "$here/lint/waivers.vlt"
  "$root/rtl/common/fifo_sync.sv" "$root/rtl/axi/axi_channel_reg_slice.sv"
  "$t/tl_pkg.sv" "$t/tl_dw_align.sv" "$t/tl_rx_buf.sv" "$t/tl_rx_unpack.sv" "$t/tl_tx_pack.sv"
  "$t/tl_cfg.sv" "$t/tl_msix.sv" "$t/tl_wr.sv" "$t/tl_rd.sv" "$t/tl_bm.sv" "$t/tl_core.sv"
  "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv"
  "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/tb_tl.sv"
)

verilator --binary --timing --assert --coverage -j 0 --timescale 1ns/1ps --top-module tb_tl \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && timeout 1800 ./obj/Vtb_tl "$@" +verilator+coverage+file+"cov_$name.dat") \
       > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[TL\] PASS' "$out/$name.log" || fail=1
  grep -E '^\[TL\]|^\[HOST\]|^\[DMA\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -60
}

for t in enum target errors msix bm bm_err perf; do
  run "$t" +test="$t" +verilator+seed+1
done
for s in $(seq 1 "$seeds"); do
  run "seed$s" +test=random +n="$n" +verilator+seed+"$s" | grep -E 'random:|ERROR|FAIL|%Error|Assertion' || true
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[TL] covergroup bins hit: $hit of $bins"
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/host/tl/

if [ "$fail" -eq 0 ] && [ "$hit" -eq "$bins" ]; then
  echo "[TL] all runs PASS"
else
  echo "[TL] FAIL"
  exit 1
fi
