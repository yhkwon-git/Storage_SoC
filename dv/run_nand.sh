#!/usr/bin/env bash
# Builds tb_nand once (with assertions and coverage) and runs the directed
# tests, then for seeds 1..SEEDS the random test, with clk_nand at 20, 17 and
# 23 ns in turn (clk_sys is 20 ns); even seeds run the model with busy times
# drawn per operation and NAND_PPM bit errors per million bits (step 3-2).
# Fails unless every run passes and every covergroup bin is hit.
#
#   SEEDS      random seeds to run (default 10)
#   NAND_N     commands per random run (default 300)
#   NAND_PPM   bit error rate of the even seeds (default 200)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/nand"
seeds="${SEEDS:-10}"
n="${NAND_N:-300}"
ppm="${NAND_PPM:-200}"
mkdir -p "$out"

r="$root/rtl"
src=(
  "$here/lint/waivers.vlt"
  "$r/common/fifo_sync.sv" "$r/common/cdc_sync_2ff.sv" "$r/common/cdc_async_fifo.sv" "$r/mem/mem_array.sv"
  "$r/csr/gen/nand_regs_pkg.sv" "$r/csr/gen/nand_regs.sv"
  "$r/nand/nand_pkg.sv" "$r/nand/nand_seq.sv" "$r/nand/nand_pbuf.sv" "$r/nand/nand_ctrl.sv"
  "$here/uvm/apb_if.sv" "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv"
  "$here/sva/nand_checker.sv" "$here/sva/nand_bind.sv" "$here/tb/nand_model.sv" "$here/tb/tb_nand.sv"
)

verilator --binary --timing --assert --coverage -j 0 --timescale 1ns/1ps --top-module tb_nand \
  "${src[@]}" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
run() {
  local name="$1"; shift
  if ! (cd "$out" && timeout 1800 ./obj/Vtb_nand "$@" +verilator+coverage+file+"cov_$name.dat") \
       > "$out/$name.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[NAND\] PASS' "$out/$name.log" || fail=1
  grep -E '^\[NAND\]|%Error|Assertion' "$out/$name.log" | sed "s/^/$name: /" | head -40
}

for t in regs reset id rw erase fail wp timeout timing queue arb softreset busy wear abort rules biterr; do
  run "$t" +test="$t" +verilator+seed+1
done
periods=(20000 17000 23000)
for s in $(seq 1 "$seeds"); do
  p="${periods[$(( (s - 1) % 3 ))]}"
  dev=()
  [ $(( s % 2 )) -eq 0 ] && dev=(+profile=1 +rber_ppm="$ppm")
  run "seed$s" +test=random +n="$n" +nand_ps="$p" "${dev[@]}" +verilator+seed+"$s" \
    | grep -E 'test random|ERROR|FAIL|%Error|Assertion' || true
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bins=$(grep -c 't.covergroup' "$out/merged.dat" || true)
hit=$(grep 't.covergroup' "$out/merged.dat" | awk '$NF > 0' | wc -l)
echo "[NAND] covergroup bins hit: $hit of $bins"
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/nand/

if [ "$fail" -eq 0 ] && [ "$hit" -eq "$bins" ]; then
  echo "[NAND] PASS"
else
  grep 't.covergroup' "$out/merged.dat" | awk '$NF == 0' | sed 's/^/[NAND] not hit: /' | cut -c1-160
  echo "[NAND] FAIL"
  exit 1
fi
