#!/usr/bin/env bash
# Mutation check for the NVMe queue testbench (tb_nvme). Each mutant copies
# rtl/host/nvme into the build directory, plants one bug with sed, builds
# tb_nvme and runs the directed tests and one random seed, stopping at the
# first failure. The testbench must fail on every mutant. The repository's RTL
# is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/nvme_mut"
f=nvme_ctrl.sv

# name @ sed expression on nvme_ctrl.sv @ what the bug does (fields split at @)
mutants=(
  "rr_fixed@s/      q = 3'((int'(rr) + k) % NQ);/      q = 3'(k - 1);/@fixed priority instead of round robin"
  "rr_hold@s/        rr      <= pick;/        rr      <= rr;/@round-robin pointer never moves"
  "wrap@s/wire \[11:0\] next_head = (sq_head\[f_q\] == sq_size\[f_q\]) ? 12'd0/wire [11:0] next_head = 1'b0 ? 12'd0/@submission queue head does not wrap"
  "stride@s/{50'd0, sq_head\[pick\]} \* 62'd16;/{50'd0, sq_head[pick]} * 62'd8;/@commands fetched at a 32-byte stride"
  "slot_used@s/        slot_free\[alloc\] <= 1'b0;/        slot_free[alloc] <= 1'b1;/@a fetched command's slot stays free"
  "cmd_slot@s/assign cf_din  = {f_q, f_slot};/assign cf_din  = {f_q, alloc};/@command FIFO reports the wrong slot"
  "db_range@s/: (sq_en\[db_q\] \&\& (db_val <= {4'd0, sq_size\[db_q\]}));/: (sq_en[db_q]);/@submission doorbell beyond the queue size taken"
  "db_event@s/        if (!db_ok)      ev_db <= 1'b1;/        if (!db_ok)      ev_db <= 1'b0;/@bad doorbell not reported"
  "cfs@s/            cfs          <= 1'b1;/            cfs          <= 1'b0;/@failed fetch does not set CFS"
  "flush@s/          cf_flush  <= 1'b1;/          cf_flush  <= 1'b0;/@controller reset leaves commands in the FIFO"
  "ioq_clr@s/      hwif_in.IOQ\[i\].SQ_CFG.en.hwclr = clr_ioq;/      hwif_in.IOQ[i].SQ_CFG.en.hwclr = 1'b0;/@controller reset leaves I/O submission queues enabled"
  "shut_wait@s/      if (shst == 2'b01 \&\& !f_busy) shst <= 2'b10;/      if (shst == 2'b01) shst <= 2'b10;/@shutdown complete with a fetch in flight"
  "shut_stop@s/wire can_fetch = (c_st == C_ON) \&\& !cfs \&\& (shst == 2'b00) \&\& any/wire can_fetch = (c_st == C_ON) \&\& !cfs \&\& any/@fetching goes on after a shutdown"
  "irq_en@s/assign irq  = (hwif_out.CTRL.ien_cmd.value \&\& !cf_empty) ||/assign irq  = (!cf_empty) ||/@command interrupt ignores CTRL.IEN_CMD"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  t="$dir/rtl/host/nvme"
  rm -rf "$t"
  mkdir -p "$t"
  cp "$root/rtl/host/nvme/$f" "$t/"
  sed -i "$expr" "$t/$f"
  if cmp -s "$root/rtl/host/nvme/$f" "$t/$f"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  tl="$root/rtl/host/tl"
  src=(
    "$here/lint/waivers.vlt"
    "$root/rtl/common/fifo_sync.sv" "$root/rtl/axi/axi_channel_reg_slice.sv"
    "$tl/tl_pkg.sv" "$tl/tl_dw_align.sv" "$tl/tl_rx_buf.sv" "$tl/tl_rx_unpack.sv" "$tl/tl_tx_pack.sv"
    "$tl/tl_cfg.sv" "$tl/tl_msix.sv" "$tl/tl_wr.sv" "$tl/tl_rd.sv" "$tl/tl_bm.sv" "$tl/tl_core.sv"
    "$root/rtl/csr/gen/nvme_regs_pkg.sv" "$root/rtl/csr/gen/nvme_regs.sv" "$t/$f"
    "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv"
    "$here/tb/tlp_if.sv" "$here/tb/tlp_tb_pkg.sv" "$here/tb/tb_nvme.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_nvme \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=regs" "+test=enable" "+test=fetch" "+test=rr" "+test=doorbell" "+test=ferr" \
              "+test=shutdown" "+test=reset" "+test=random +n=600"; do
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
