#!/usr/bin/env bash
# Builds tb_axi_xbar once (with assertions and coverage) and runs the directed
# test, then the random test for seeds 1..SEEDS.
#
#   SEEDS      random seeds to run (default 10)
#   N          bursts per master in each random run (default 2000)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/xbar"
seeds="${SEEDS:-10}"
n="${N:-2000}"
mkdir -p "$out"

rtl="$root/rtl"
src=(
  "$rtl/common/rr_arb.sv" "$rtl/common/fifo_sync.sv"
  "$rtl/axi/axi_id_tracker.sv" "$rtl/axi/axi_err_slv.sv" "$rtl/axi/axi_xbar.sv"
  "$here/tb/axi4_if.sv" "$here/tb/axi_tb_pkg.sv" "$here/sva/axi4_checker.sv"
  "$here/tb/tb_axi_xbar.sv"
)

verilator --binary --timing --assert --coverage -j 0 --top-module tb_axi_xbar \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && ./obj/Vtb_axi_xbar "$@" +verilator+coverage+file+"cov_$name.dat") \
       > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -E '^\[XBAR\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -40
}

run directed +test=directed +verilator+seed+1
for s in $(seq 1 "$seeds"); do
  run "seed$s" +test=random +n="$n" +verilator+seed+"$s" | grep -E 'random:|errors|ERROR|%Error|Assertion' || true
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[XBAR] covergroup bins hit: $hit of $bins"
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/

if [ "$fail" -eq 0 ] && [ "$hit" -eq "$bins" ]; then
  echo "[XBAR] all runs PASS"
else
  echo "[XBAR] FAIL"
  exit 1
fi
