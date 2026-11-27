#!/usr/bin/env bash
# BCH codec against its Python reference model (step 3-3): checks that
# rtl/ecc/bch_pkg.sv is what flow/bch/bch.py generates, runs the model's own
# check, writes BCH_NV test vectors for each of three seeds and runs tb_bch on
# them: with gaps in the input and back-pressure on the corrections (seed 1),
# back to back (seed 2), and with long gaps and heavy back-pressure (seed 3).
# Prints the RTL coverage of rtl/ecc/ over the three runs.
#
#   BCH_NV     vectors per seed (default 600)
#   PYTHON     Python 3 to run the model with (default python3)
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${BUILD_DIR:-$root/build/dv}/bch"
nv="${BCH_NV:-600}"
py="${PYTHON:-python3}"
mkdir -p "$out"

"$py" "$root/flow/bch/bch.py" --pkg "$out/bch_pkg.sv" > /dev/null
if ! cmp -s "$out/bch_pkg.sv" "$root/rtl/ecc/bch_pkg.sv"; then
  echo "[BCH] rtl/ecc/bch_pkg.sv differs from flow/bch/bch.py --pkg"
  exit 1
fi
"$py" "$root/flow/bch/bch.py" --self --words 110 | sed -n 2p

r="$root/rtl/ecc"
verilator --binary --timing --assert --coverage -j 0 --timescale 1ns/1ps --top-module tb_bch \
  "$here/lint/waivers.vlt" "$r/bch_pkg.sv" "$r/bch_enc.sv" "$r/bch_syn.sv" "$r/bch_bm.sv" \
  "$r/bch_chien.sv" "$r/bch_dec.sv" "$here/tb/tb_bch.sv" -Mdir "$out/obj" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; exit 1; }

rm -f "$out"/cov_*.dat
fail=0
modes=("+gap=30 +bp=30" "+gap=0 +bp=0" "+gap=60 +bp=90")
for s in 1 2 3; do
  "$py" "$root/flow/bch/bch.py" --vectors "$out/vec$s.hex" --nv "$nv" --seed "$s" | sed -n 2p
  # shellcheck disable=SC2086
  if ! (cd "$out" && timeout 1800 ./obj/Vtb_bch +vec="vec$s.hex" +nv="$nv" ${modes[$((s - 1))]} \
          +verilator+seed+"$s" +verilator+coverage+file+"cov_seed$s.dat") > "$out/seed$s.log" 2>&1; then
    fail=1
  fi
  grep -q '^\[BCH\] PASS' "$out/seed$s.log" || fail=1
  grep -E '^\[BCH\]|%Error|Assertion' "$out/seed$s.log" | sed "s/^/seed$s: /" | head -24
done

verilator_coverage --write "$out/merged.dat" "$out"/cov_*.dat > /dev/null
bash "$here/cov_summary.sh" "$out/merged.dat" /rtl/ecc/

if [ "$fail" -eq 0 ]; then
  echo "[BCH] PASS"
else
  echo "[BCH] FAIL"
  exit 1
fi
