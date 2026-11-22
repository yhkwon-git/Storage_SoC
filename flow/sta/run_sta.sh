#!/usr/bin/env bash
# Static timing of build/syn/soc_top.nl.v at the three Sky130 HD corners with
# OpenSTA (docs/09_timing.md). Sign-off rule (docs/01, section 9): setup at
# ss_n40C_1v40, hold at ff_100C_1v95, tt_025C_1v80 reported.
#
#   BUILD_DIR  build root (default: build); PDK_DIR (default: build/pdk);
#   STA        the OpenSTA binary (default: sta on PATH)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build="${BUILD_DIR:-$root/build}"
pdk="${PDK_DIR:-$root/build/pdk}"
sta="${STA:-sta}"
out="$build/sta"
netlist="$build/syn/soc_top.nl.v"
mkdir -p "$out"
[ -s "$netlist" ] || { echo "[STA] $netlist missing: run flow/syn/run_syn.sh"; exit 1; }

python3 "$root/flow/syn/gen_sram_lib.py" > /dev/null

declare -A lib=(
  [ss]=sky130_fd_sc_hd__ss_n40C_1v40.lib
  [tt]=sky130_fd_sc_hd__tt_025C_1v80.lib
  [ff]=sky130_fd_sc_hd__ff_100C_1v95.lib
)

for c in ss tt ff; do
  cat > "$out/run_$c.tcl" <<EOF
set lib     $pdk/${lib[$c]}
set macros  $root/syn/lib/sram_macros.lib
set netlist $netlist
set sdc     $root/syn/sdc/soc_top.sdc
set corner  $c
set out     $out
source $here/sta.tcl
EOF
  "$sta" -no_splash -exit "$out/run_$c.tcl" > "$out/sta_$c.log" 2>&1 || { tail -20 "$out/sta_$c.log"; exit 1; }
done

for c in ss tt ff; do
  s="$out/summary_$c.txt"
  printf '[STA] %s: setup WNS %8s ns, TNS %10s ns; hold WNS %8s ns, TNS %8s ns\n' "$c" \
    "$(awk '$1=="setup_wns"{print $2}' "$s")" "$(awk '$1=="setup_tns"{print $2}' "$s")" \
    "$(awk '$1=="hold_wns"{print $2}' "$s")" "$(awk '$1=="hold_tns"{print $2}' "$s")"
done
ss_setup=$(awk '$1=="setup_wns"{print $2}' "$out/summary_ss.txt")
ff_hold=$(awk '$1=="hold_wns"{print $2}' "$out/summary_ff.txt")
if awk -v a="$ss_setup" -v b="$ff_hold" 'BEGIN{exit !(a >= 0 && b >= 0)}'; then
  echo "[STA] sign-off met: setup at ss, hold at ff"
else
  echo "[STA] sign-off NOT met: setup at ss $ss_setup ns, hold at ff $ff_hold ns"
fi
