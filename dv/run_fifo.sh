#!/usr/bin/env bash
# Builds tb_cdc_async_fifo once and runs it at six clock pairs, each with
# random traffic (70% push, 70% pop) and with full-rate traffic (100/100).
#
#   FIFO_SRC   FIFO sources to test (default: this repository's)
#   MIN_EFF    full-rate pass threshold, percent of the bound (default 95;
#              0 = report only)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/fifo"
src="${FIFO_SRC:-$root/rtl/common/cdc_sync_2ff.sv $root/rtl/common/cdc_async_fifo.sv}"
min_eff="${MIN_EFF:-95}"
mkdir -p "$out"

# Every delay in the testbench is non-zero at run time, so zero-delay
# scheduling is off.
# shellcheck disable=SC2086
verilator --binary --timing --no-sched-zero-delay -j 0 --top-module tb_cdc_async_fifo \
  $src "$here/tb/tb_cdc_async_fifo.sv" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

fail=0
# wr_ps rd_ps rd_off_ps
for clocks in "10000 8000 0" "16000 20000 0" "20000 16000 0" "20000 20000 3000" \
              "40000 10000 0" "10000 40000 0"; do
  for traffic in "70 70 0" "100 100 $min_eff"; do
    # shellcheck disable=SC2086
    set -- $clocks $traffic
    if ! "$out/obj/Vtb_cdc_async_fifo" +wr_ps="$1" +rd_ps="$2" +rd_off_ps="$3" \
         +push_pct="$4" +pop_pct="$5" +min_eff="$6" +verilator+seed+7 \
         2>&1 | grep -E '^\[FIFO\] (wr|ERROR)'; then
      fail=1
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "[FIFO] all runs PASS"
else
  echo "[FIFO] FAIL"
  exit 1
fi
