#!/usr/bin/env bash
# Mutation check for the NAND channel testbench (tb_nand). Each mutant copies
# rtl/nand into the build directory, plants one bug with sed in one of its
# files (the ecc_ ones in the BCH path of step 3-3), builds tb_nand and runs
# the directed tests and one random seed, stopping at the first failure. The testbench must fail on every mutant. The
# repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/nand_mut"

# name @ file in rtl/nand @ sed expression @ what the bug does (fields split at @)
mutants=(
  "cle_lost@nand_seq.sv@s/              cle   <= (sk == K_CMD);/              cle   <= 1'b0;/@command cycles without CLE"
  "col_hi@nand_seq.sv@s/return {3'd0, col\[12:8\]};/return 8'd0;/@the column's high address byte always 0"
  "row_mid@nand_seq.sv@s/return row\[15:8\];/return 8'd0;/@the row's middle address byte always 0"
  "twb_short@nand_seq.sv@s/4'd9:                         begin sk = K_WAIT; sw = 2'd0; end/4'd9:                         begin sk = K_WAIT; sw = 2'd3; end/@a program looks at R/B# after tRR instead of tWB"
  "no_timeout@nand_seq.sv@s/  wire tout_hit = (c.tout != 16'd0) \&\& (busy\[23:8\] >= c.tout);/  wire tout_hit = 1'b0;/@a busy device is waited for without limit"
  "no_prot@nand_seq.sv@s/if (wr_op) code <= !status\[7\] ? CODE_PROT : status\[0\] ? CODE_FAIL : CODE_OK;/if (wr_op) code <= status[0] ? CODE_FAIL : CODE_OK;/@write protection reported as a failure"
  "no_rb_wait@nand_seq.sv@s/          if (rb_s) begin/          if (1'b1) begin/@R/B# not waited for"
  "wp_high@nand_seq.sv@s/  assign wp_n = wen_s;/  assign wp_n = 1'b1;/@WP# never asserted"
  "twp_twh@nand_seq.sv@s/^              cnt   <= w1({2'd0, c.twp});/              cnt   <= w1({2'd0, c.twh});/@command and address cycles take tWH for tWP"
  "status_byte@nand_seq.sv@s/            if (rd_stat) status <= dq_i;/            if (rd_stat) status <= 8'hE0;/@the status byte is never read"

  "tx_order@nand_ctrl.sv@s/  assign tx_buf  = w_data\[8 \* bptr\[2:0\] +: 8\];/  assign tx_buf  = w_data[8 * {bptr[2:1], ~bptr[0]} +: 8];/@program bytes swapped in pairs"
  "rx_mask@nand_ctrl.sv@s/  assign x_we    = a_pend ? am : /  assign x_we    = a_pend ? 8'hFF : /@read data writes whole buffer words"
  "no_ovf@nand_ctrl.sv@s/    hwif_in.EVENT.ovf.hwset       = go \&\& q_full;/    hwif_in.EVENT.ovf.hwset       = 1'b0;/@a dropped command not reported"
  "cq_room@nand_ctrl.sv@s/  wire dispatch = !d_run \&\& !q_empty \&\& !x_cmd_full \&\& (cq_count != 4'd8);/  wire dispatch = !d_run \&\& !q_empty \&\& !x_cmd_full;/@a command dispatched with no room for its completion"
  "early_cpl@nand_ctrl.sv@s/  wire complete = d_run \&\& !x_cpl_empty \&\& (s_done || (x_cpl.code != CODE_OK));/  wire complete = d_run \&\& !x_cpl_empty;/@a read completes before its data is in the buffer"
  "no_err@nand_ctrl.sv@s/    hwif_in.EVENT.err.hwset       = complete \&\& (cpl_code != 3'd0);/    hwif_in.EVENT.err.hwset       = 1'b0;/@a failed command does not set EVENT.ERR"

  "rd_conflict@nand_pbuf.sv@s/  assign x_rgnt  = x_re \&\& !axi_re \&\& !(s_rvalid \&\& !s_rready);/  assign x_rgnt  = x_re \&\& !axi_re;/@a stream read replaces an AXI beat the master has not taken"
  "wr_conflict@nand_pbuf.sv@s/  assign x_wgnt  = (x_we != 8'd0) \&\& !w_hs;/  assign x_wgnt  = (x_we != 8'd0);/@a stream write granted in the clock of an AXI write"

  "ecc_hole@nand_ctrl.sv@s/  wire        e_hole = ecc \&\& (e_col == E_HOLE);/  wire        e_hole = 1'b0;/@no column left out of the codewords for the marker"
  "ecc_meta@nand_ctrl.sv@s/: off + 13'd4096 + {8'd0, cw, 2'd0} + {3'd0, j - 10'd512};/: off + 13'd4096 + {9'd0, cw, 1'd0} + {3'd0, j - 10'd512};/@a codeword's metadata 2 bytes after the last one's instead of 4"
  "ecc_txmask@nand_ctrl.sv@s/: e_msg ? tx_buf : enc_par ^ e_mask;/: e_msg ? tx_buf : enc_par;/@parity programmed without the mask"
  "ecc_rxmask@nand_ctrl.sv@s/.din (rx_byte ^ e_mask), .ready/.din (rx_byte), .ready/@parity read without the mask"
  "ecc_coraddr@nand_ctrl.sv@s/c_addr = e_addr_of(s_off, r_cw, cor_idx);/c_addr = e_addr_of(s_off, e_cw, cor_idx);/@a correction applied to the codeword streaming in"
  "ecc_early@nand_ctrl.sv@s/(r_cnt == 4'd8 \&\& c_st == C_IDLE)/(r_cnt == 4'd7 \&\& c_st == C_IDLE)/@a read completes before the last codeword's result"
  "ecc_code@nand_ctrl.sv@s/e_unc != 8'd0) ? 3'd4 : 3'd0;/e_unc != 8'd0) ? 3'd0 : 3'd0;/@a codeword past correcting not reported in the code"
  "ecc_erased@nand_ctrl.sv@s/(zc\[r_cw\] <= 4'(bch_pkg::T)) e_erased\[r_cw\] <= 1'b1;/(zc[r_cw] <= 4'(bch_pkg::T)) e_erased[r_cw] <= 1'b0;/@erased codewords never reported"
  "ecc_count@nand_ctrl.sv@s/        n_ebits   <= n_ebits + {9'd0, e_bits};/        n_ebits   <= n_ebits;/@corrected bits not counted in ECC_COUNT"
  "ecc_flush@nand_ctrl.sv@s/(e_j == 10'd511 || e_j == 10'(bch_pkg::K_BYTES - 1))/(e_j == 10'd511)/@the metadata word not written when its bytes end"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name f expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  t="$dir/rtl/nand"
  rm -rf "$t"
  mkdir -p "$t"
  cp "$root"/rtl/nand/*.sv "$t/"
  sed -i "$expr" "$t/$f"
  if cmp -s "$root/rtl/nand/$f" "$t/$f"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  r="$root/rtl"
  src=(
    "$here/lint/waivers.vlt"
    "$r/common/fifo_sync.sv" "$r/common/cdc_sync_2ff.sv" "$r/common/cdc_async_fifo.sv" "$r/mem/mem_array.sv"
    "$r/csr/gen/nand_regs_pkg.sv" "$r/csr/gen/nand_regs.sv"
    "$r/ecc/bch_pkg.sv" "$r/ecc/bch_enc.sv" "$r/ecc/bch_syn.sv" "$r/ecc/bch_bm.sv" "$r/ecc/bch_chien.sv" "$r/ecc/bch_dec.sv"
    "$t/nand_pkg.sv" "$t/nand_seq.sv" "$t/nand_pbuf.sv" "$t/nand_ctrl.sv"
    "$here/uvm/apb_if.sv" "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv"
    "$here/sva/nand_checker.sv" "$here/sva/nand_bind.sv" "$here/tb/nand_model.sv" "$here/tb/tb_nand.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_nand \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=regs" "+test=reset" "+test=id" "+test=rw" "+test=erase" "+test=fail" "+test=wp" \
              "+test=timeout" "+test=timing" "+test=queue" "+test=arb" "+test=softreset" \
              "+test=ecc" "+test=eccerr" "+test=eccrand +n=160" \
              "+test=busy" "+test=wear" "+test=abort" "+test=rules" "+test=biterr" "+test=random +n=150"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 "$base/obj/Vtb_nand" $args +verilator+seed+1) > "$dir/run.log" 2>&1; then
      first=$( (grep -m1 -E 'ERROR|%Error|Assertion|FAIL' "$dir/run.log" || true) | cut -c1-150)
      [ -n "$first" ] || first="non-zero exit"
      break
    fi
  done
  if [ -n "$first" ]; then
    caught=$((caught + 1))
    echo "[MUT] $name ($what): caught by $args -- $first"
  else
    echo "[MUT] $name ($what): SURVIVED"
  fi
done

echo "[MUT] $caught of $total mutants caught"
[ "$caught" -eq "$total" ]
