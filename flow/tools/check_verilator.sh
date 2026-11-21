#!/usr/bin/env bash
# Toolchain check, Verilator side. Builds smoke_cov.sv with --coverage and
# checks that all 14 covergroup bins (4 + 2 + 8 cross) are in coverage.dat
# with a non-zero hit count.
# BUILD_DIR defaults to build/tools/verilator in the repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${BUILD_DIR:-$here/../../build/tools/verilator}"
mkdir -p "$out"

verilator --version
verilator --binary --coverage -Wall --top-module smoke_cov \
  "$here/smoke_cov.sv" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

cd "$out"
rm -f coverage.dat
./obj/Vsmoke_cov | grep '\[SMOKE\]'

bins=$(grep -c 't.covergroup' coverage.dat || true)
hit=$(grep 't.covergroup' coverage.dat | awk '$NF > 0' | wc -l)
echo "[TOOLS] covergroup bins in coverage.dat: $bins, hit: $hit (expect 14, 14)"
if [ "$bins" -eq 14 ] && [ "$hit" -eq 14 ]; then
  echo "[TOOLS] verilator PASS"
else
  echo "[TOOLS] verilator FAIL"
  exit 1
fi
