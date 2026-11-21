#!/usr/bin/env bash
# Mutation check for the crossbar testbench. Each mutant copies the RTL into
# the build directory, plants one bug with sed, builds tb_axi_xbar and runs the
# directed test and one random seed. The testbench must fail on every mutant.
# The repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/xbar_mut"

# name | file | sed expression | what the bug does
mutants=(
  "id_rule|axi/axi_id_tracker.sv|s/assign allow    = (total < CW'(MAX_OUT)) \&\& !id_block;/assign allow    = (total < CW'(MAX_OUT));/|same-ID requests may go to a second slave"
  "max_out|axi/axi_id_tracker.sv|s/(total < CW'(MAX_OUT))/(total <= CW'(MAX_OUT))/|one more outstanding than MAX_OUT"
  "r_lock|axi/axi_xbar.sv|s/assign keep_r = s_rvalid\[m\] ? !(s_rready\[m\] \&\& s_rlast\[m\]) : r_inburst\[m\];/assign keep_r = s_rvalid[m] \&\& !s_rready[m];/|R grant not held to RLAST"
  "aw_hold|axi/axi_xbar.sv|s/\.keep  (m_awvalid\[s\] \&\& !m_awready\[s\]),/.keep  (1'b0),/|AW grant may move while AWVALID waits"
  "w_order|axi/axi_xbar.sv|s/wready_m = !ws_empty\[s\] \&\& (ws_head\[s\] == MW'(m)) \&\& m_wready\[s\];/wready_m = m_wready[s];/|W accepted without the slave's AW order"
  "conn|axi/axi_xbar.sv|s/if (conn\[s\] \&\& ((a \& SLV_MASK\[s\]) == SLV_BASE\[s\])) t = TW'(s);/if ((a \& SLV_MASK[s]) == SLV_BASE[s]) t = TW'(s);/|path table ignored in the decoder"
  "b_route|axi/axi_xbar.sv|s/assign b_sreq\[m\]\[s\] = m_bvalid\[s\] \&\& (m_bid\[s\]\[SIDW-1:MIDW\] == MW'(m));/assign b_sreq[m][s] = m_bvalid[s] \&\& (m_bid[s][SIDW-1:MIDW] != MW'(m));/|B routed to the wrong masters"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='|' read -r name file expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  rm -rf "$dir/rtl"
  mkdir -p "$dir/rtl"
  cp -r "$root/rtl/common" "$root/rtl/axi" "$dir/rtl/"
  sed -i "$expr" "$dir/rtl/$file"
  if cmp -s "$root/rtl/$file" "$dir/rtl/$file"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  src=(
    "$dir/rtl/common/rr_arb.sv" "$dir/rtl/common/fifo_sync.sv"
    "$dir/rtl/axi/axi_id_tracker.sv" "$dir/rtl/axi/axi_err_slv.sv" "$dir/rtl/axi/axi_xbar.sv"
    "$here/tb/axi4_if.sv" "$here/tb/axi_tb_pkg.sv" "$here/sva/axi4_checker.sv"
    "$here/tb/tb_axi_xbar.sv"
  )
  verilator --binary --timing --assert -j 0 --top-module tb_axi_xbar \
    "${src[@]}" -Mdir "$dir/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=directed" "+test=random +n=500"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 ./obj/Vtb_axi_xbar $args +verilator+seed+1) > "$dir/run.log" 2>&1; then
      first=$( (grep -m1 -E 'ERROR|%Error|Assertion|FAIL' "$dir/run.log" || true) | cut -c1-150)
      [ -n "$first" ] || first="non-zero exit"
      break
    fi
  done
  if [ -n "$first" ]; then
    caught=$((caught + 1))
    echo "[MUT] $name ($what): caught by $args -- $first"
  else
    echo "[MUT] $name ($what): NOT caught"
  fi
done

echo "[MUT] $caught of $total mutants caught"
[ "$caught" -eq "$total" ]
