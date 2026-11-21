#!/usr/bin/env bash
# Builds tb_dma once (with assertions and coverage) and runs the directed
# test, then the random test for seeds 1..SEEDS. Fails unless every run
# passes and every covergroup bin is hit.
#
#   SEEDS      random seeds to run (default 10)
#   DMA_N      chains per random run (default 200)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/dma"
seeds="${SEEDS:-10}"
n="${DMA_N:-200}"
mkdir -p "$out"

rtl="${DMA_RTL:-$root/rtl}"
src=(
  "$here/lint/waivers.vlt"
  "$root/rtl/csr/gen/dma_regs_pkg.sv" "$root/rtl/csr/gen/dma_regs.sv"
  "$root/rtl/common/fifo_sync.sv" "$rtl/dma/dma.sv"
  "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv" "$here/tb/tb_dma.sv"
)

verilator --binary --timing --assert --coverage -j 0 --timescale 1ns/1ps --top-module tb_dma \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && timeout 1200 ./obj/Vtb_dma "$@" +verilator+coverage+file+"cov_$name.dat") \
       > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[DMA\] .*: PASS' "$out/$name.log" || fail=1
  grep -E '^\[DMA\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -60
}

run directed +test=directed +verilator+seed+1
for s in $(seq 1 "$seeds"); do
  run "seed$s" +test=random +n="$n" +verilator+seed+"$s" | grep -E 'random:|ERROR|FAIL|%Error|Assertion' || true
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[DMA] covergroup bins hit: $hit of $bins"
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/dma/

if [ "$fail" -eq 0 ] && [ "$hit" -eq "$bins" ]; then
  echo "[DMA] all runs PASS"
else
  echo "[DMA] FAIL"
  exit 1
fi
