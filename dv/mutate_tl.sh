#!/usr/bin/env bash
# Mutation check for the transaction-layer testbench (tb_tl). Each mutant
# copies rtl/host/tl into the build directory, plants one bug with sed, builds
# tb_tl and runs the directed tests and one random seed, stopping at the first
# failure. The testbench must fail on every mutant. The repository's RTL is
# never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/tl_mut"

# name @ file in rtl/host/tl @ sed expression @ what the bug does (fields split at @)
mutants=(
  "fence@tl_rd.sv@s/wire        fence_ok  = !fence_d\[7\];/wire        fence_ok  = 1'b1;/@a read does not wait for earlier writes"
  "credit@tl_rd.sv@s/wire        room      = (credit_used + (BW+1)'(ch_beats) <= (BW+1)'(BUF_DEPTH)) \&\&/wire        room      = 1'b1 \&\&/@reads issued without room in the completion buffer"
  "split@tl_rd.sv@s/wire \[5:0\]  to_bound  = 6'd32 - {1'b0, cur_dw\[4:0\]};/wire [5:0]  to_bound  = 6'd32;/@read bursts not split at 128-byte boundaries"
  "bc@tl_rd.sv@s/g_bc    <= g_bc - g_ch_bytes;/g_bc    <= g_bc;/@Byte Count not reduced after a completion"
  "la@tl_rd.sv@s/wire \[6:0\]  g_la       = g_first ? q_la : {g_a, 2'b00};/wire [6:0]  g_la       = q_la;/@Lower Address of later completions wrong"
  "last_be@tl_wr.sv@s/if (i == n - 11'd1) return l;/if (1'b0) return l;/@Last BE ignored on writes"
  "mse@tl_core.sv@s/wire bar2_hit = mse \&\& (addr\[63:15\] == bar2\[63:15\]);/wire bar2_hit = (addr[63:15] == bar2[63:15]);/@Memory Space Enable ignored for BAR2"
  "be_rule@tl_core.sv@s/wire be_bad  = (len == 11'd1) ? (lbe != 4'd0) : ((fbe == 4'd0) || (lbe == 4'd0));/wire be_bad  = 1'b0;/@byte-enable rules not checked"
  "timeout@tl_bm.sv@s/if (tick \&\& t_st\[i\] == T_BUSY \&\& !cto_dis \&\& (t_age\[i\] >= cto_ticks) \&\&/if (1'b0 \&\& t_st[i] == T_BUSY \&\& !cto_dis \&\& (t_age[i] >= cto_ticks) \&\&/@completion timeout not reported"
  "cpl_bc@tl_bm.sv@s/(c_bc == t_rem\[ct\]\[11:0\]) \&\&/1'b1 \&\&/@Byte Count of completions not checked"
  "msix_mask@tl_msix.sv@s/ready_v = pending \& ~t_mask;/ready_v = pending;/@MSI-X vector mask ignored"
  "rx_len@tl_rx_buf.sv@s/if (in_sop || (cnt_now > dw_exp) || (in_eop \&\& (cnt_now != dw_exp))) begin/if (in_sop) begin/@TLPs not checked against their Length"
  "align_tail@tl_dw_align.sv@s/        if (left != 2'd0) begin/        if (1'b0) begin/@aligner drops the DW left over at a packet's end"
  "arb_prio@tl_core.sv@s/wire  grant_nv  = bm_req_ready \&\& nv_valid \&\& (!csr_pend || !last_nv);/wire  grant_nv  = bm_req_ready \&\& nv_valid;/@NVMe port always wins the bus master"
  "nv_done@tl_core.sv@s/assign nv_done  = q_done \&\& own_nv;/assign nv_done  = q_done;/@done of a HOST-register transfer also reaches the NVMe port"
  "rp_be@tl_core.sv@s/assign rp_be    = mx_be;/assign rp_be    = 4'hF;/@byte enables of BAR0 register writes ignored"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name file expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  t="$dir/rtl/host/tl"
  rm -rf "$t"
  mkdir -p "$t"
  cp "$root"/rtl/host/tl/*.sv "$t/"
  sed -i "$expr" "$t/$file"
  if cmp -s "$root/rtl/host/tl/$file" "$t/$file"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  src=(
    "$here/lint/waivers.vlt"
    "$root/rtl/common/fifo_sync.sv" "$root/rtl/axi/axi_channel_reg_slice.sv"
    "$t/tl_pkg.sv" "$t/tl_dw_align.sv" "$t/tl_rx_buf.sv" "$t/tl_rx_unpack.sv" "$t/tl_tx_pack.sv"
    "$t/tl_cfg.sv" "$t/tl_msix.sv" "$t/tl_wr.sv" "$t/tl_rd.sv" "$t/tl_bm.sv" "$t/tl_core.sv"
    "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv"
    "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/tb_tl.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_tl \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=target" "+test=errors" "+test=msix" "+test=bm" "+test=bm_err" "+test=random +n=600"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 "$base/obj/Vtb_tl" $args +verilator+seed+1) > "$dir/run.log" 2>&1; then
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
