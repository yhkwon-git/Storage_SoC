#!/usr/bin/env bash
# Mutation check for the NVMe testbench (tb_nvme). Each mutant copies
# rtl/host/nvme into the build directory, plants one bug with sed in one of its
# files, builds tb_nvme and runs the directed tests, one random queue seed and
# one random I/O seed, stopping at the first failure. The testbench must fail
# on every mutant. The repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/nvme_mut"

# name @ file in rtl/host/nvme @ sed expression @ what the bug does (fields split at @)
mutants=(
  "rr_fixed@nvme_ctrl.sv@s/      q = 3'((int'(rr) + k) % NQ);/      q = 3'(k - 1);/@fixed priority instead of round robin"
  "rr_hold@nvme_ctrl.sv@s/        rr      <= pick;/        rr      <= rr;/@round-robin pointer never moves"
  "wrap@nvme_ctrl.sv@s/wire \[11:0\] next_head = (sq_head\[f_q\] == sq_size\[f_q\]) ? 12'd0/wire [11:0] next_head = 1'b0 ? 12'd0/@submission queue head does not wrap"
  "stride@nvme_ctrl.sv@s/{50'd0, sq_head\[pick\]} \* 62'd16;/{50'd0, sq_head[pick]} * 62'd8;/@commands fetched at a 32-byte stride"
  "slot_used@nvme_ctrl.sv@s/        slot_free\[alloc\] <= 1'b0;/        slot_free[alloc] <= 1'b1;/@a fetched command's slot stays free"
  "cmd_slot@nvme_ctrl.sv@s/assign cf_din  = {f_q, f_slot};/assign cf_din  = {f_q, alloc};/@command FIFO reports the wrong slot"
  "db_range@nvme_ctrl.sv@s/: (sq_en\[db_q\] \&\& (db_val <= {4'd0, sq_size\[db_q\]}));/: (sq_en[db_q]);/@submission doorbell beyond the queue size taken"
  "db_event@nvme_ctrl.sv@s/        if (!db_ok)      ev_db <= 1'b1;/        if (!db_ok)      ev_db <= 1'b0;/@bad doorbell not reported"
  "cfs@nvme_ctrl.sv@s/            cfs          <= 1'b1;/            cfs          <= 1'b0;/@failed fetch does not set CFS"
  "flush@nvme_ctrl.sv@s/          cf_flush  <= 1'b1;/          cf_flush  <= 1'b0;/@controller reset leaves commands in the FIFO"
  "ioq_clr@nvme_ctrl.sv@s/      hwif_in.IOQ\[i\].SQ_CFG.en.hwclr = clr_ioq;/      hwif_in.IOQ[i].SQ_CFG.en.hwclr = 1'b0;/@controller reset leaves I/O submission queues enabled"
  "shut_wait@nvme_ctrl.sv@s/      if (shst == 2'b01 \&\& !f_busy \&\& !p_busy \&\& !c_active) shst <= 2'b10;/      if (shst == 2'b01) shst <= 2'b10;/@shutdown complete with a fetch in flight"
  "shut_stop@nvme_ctrl.sv@s/wire can_fetch = (c_st == C_ON) \&\& !cfs \&\& (shst == 2'b00) \&\& any/wire can_fetch = (c_st == C_ON) \&\& !cfs \&\& any/@fetching goes on after a shutdown"
  "irq_en@nvme_ctrl.sv@s/assign irq  = (hwif_out.CTRL.ien_cmd.value \&\& !cf_empty) ||/assign irq  = (!cf_empty) ||/@command interrupt ignores CTRL.IEN_CMD"

  "first_room@nvme_prp.sv@s/  wire \[10:0\] first_room = 11'd1024 - {1'b0, prp1\[11:2\]};/  wire [10:0] first_room = 11'd1024;/@the first page's offset ignored: data runs past its end"
  "chain@nvme_prp.sv@s/  wire        chains     = ({3'd0, pages_left} > slots_left) \&\& (in_page <= 10'd8);/  wire        chains     = 1'b0;/@a list page's last entry never taken as the pointer to the next"
  "lp_adv@nvme_prp.sv@s/          if (x_i == x_k - 4'd1) x_lp <= x_lp + {57'd0, x_k};/          if (x_i == x_k - 4'd1) x_lp <= x_lp;/@the next batch of list entries fetched from the same place"
  "prp2_chk@nvme_prp.sv@s/(rest != 17'd0 \&\& rest <= 17'd1024 \&\& prp2\[11:0\] != 12'd0) ||/1'b0 ||/@a second-page PRP2 with an offset not refused"
  "laddr@nvme_prp.sv@s/            x_l   <= x_l + {19'd0, c_n};/            x_l   <= x_l;/@every page goes to the same SRAM address"
  "maxlen@nvme_prp.sv@s/          if (len == 16'd0 || {1'b0, len} > MAX_DW) begin/          if (len == 16'd0) begin/@a length over 128 KiB not refused"
  "phase@nvme_cqe.sv@s/      e_wdata = {h_status, cq_phase, h_cid, 13'd0, h_sq, 4'd0, sq_head};/      e_wdata = {h_status, 1'b1, h_cid, 13'd0, h_sq, 4'd0, sq_head};/@phase tag always 1"
  "cq_full@nvme_cqe.sv@s/  wire        q_full    = (tail_next == cq_head);/  wire        q_full    = 1'b0;/@entries written into a full completion queue"
  "sqhd@nvme_cqe.sv@s/      e_wdata = {h_status, cq_phase, h_cid, 13'd0, h_sq, 4'd0, sq_head};/      e_wdata = {h_status, cq_phase, h_cid, 13'd0, h_sq, 4'd0, 12'd0};/@SQ head 0 in every entry"
  "msix_vec@nvme_cqe.sv@s/  assign msix_vec = w_iv;/  assign msix_vec = 3'd0;/@every completion queue signals vector 0"
  "tail_wrap@nvme_ctrl.sv@s/            cq_tail\[i\] <= (cq_tail\[i\] == cq_size\[i\]) ? 12'd0 : cq_tail\[i\] + 12'd1;/            cq_tail[i] <= cq_tail[i] + 12'd1;/@completion queue tail does not wrap"
  "f_done@nvme_ctrl.sv@s/  wire f_done_w  = bm_done \&\& own_busy \&\& (own == 2'd0);/  wire f_done_w  = bm_done \&\& own_busy;/@the fetch engine takes another requester's done as its own"
  "werr_cfs@nvme_ctrl.sv@s/      if (c_werr) cfs <= 1'b1;/      if (1'b0) cfs <= 1'b1;/@a failed entry write does not set CSTS.CFS"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name f expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  t="$dir/rtl/host/nvme"
  rm -rf "$t"
  mkdir -p "$t"
  cp "$root"/rtl/host/nvme/*.sv "$t/"
  sed -i "$expr" "$t/$f"
  if cmp -s "$root/rtl/host/nvme/$f" "$t/$f"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  tl="$root/rtl/host/tl"
  src=(
    "$here/lint/waivers.vlt"
    "$root/rtl/common/fifo_sync.sv" "$root/rtl/common/rr_arb.sv" "$root/rtl/axi/axi_channel_reg_slice.sv"
    "$root/rtl/axi/axi_id_tracker.sv" "$root/rtl/axi/axi_err_slv.sv" "$root/rtl/axi/axi_xbar.sv"
    "$tl/tl_pkg.sv" "$tl/tl_dw_align.sv" "$tl/tl_rx_buf.sv" "$tl/tl_rx_unpack.sv" "$tl/tl_tx_pack.sv"
    "$tl/tl_cfg.sv" "$tl/tl_msix.sv" "$tl/tl_wr.sv" "$tl/tl_rd.sv" "$tl/tl_bm.sv" "$tl/tl_core.sv"
    "$root/rtl/csr/gen/nvme_regs_pkg.sv" "$root/rtl/csr/gen/nvme_regs.sv"
    "$t/nvme_lbuf.sv" "$t/nvme_prp.sv" "$t/nvme_cqe.sv" "$t/nvme_ctrl.sv"
    "$here/uvm/apb_if.sv" "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv"
    "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/tb_nvme.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_nvme \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=regs" "+test=enable" "+test=fetch" "+test=rr" "+test=doorbell" "+test=ferr" \
              "+test=shutdown" "+test=reset" "+test=data" "+test=cqe" "+test=xerr" \
              "+test=random +n=600" "+test=io +n=150"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 "$base/obj/Vtb_nvme" $args +verilator+seed+1) > "$dir/run.log" 2>&1; then
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
