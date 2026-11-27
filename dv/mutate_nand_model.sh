#!/usr/bin/env bash
# Mutation check for the NAND model's device behavior (step 3-2,
# docs/16_nand_model.md). Each mutant copies dv/tb/nand_model.sv into the
# build directory, plants one bug with sed, builds tb_nand with it and runs
# the device tests and a random run with busy times drawn and bit errors,
# stopping at the first failure. The testbench must fail on every mutant:
# what it checks of the model holds the model to its description. The
# repository's model is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/nand_model_mut"

# name @ sed expression @ what the bug does (fields split at @)
mutants=(
  "no_rate@s/    if (p > 0.0) begin/    if (p > 1.0) begin/@no bit errors at any rate"
  "log_drop@s/    flip_log\[row\] = lg;/    if (lg.size() > 0) lg.delete(0); flip_log[row] = lg;/@the log leaves out the first flipped bit"
  "win_less@s/need = win_cnt\[w\];/need = win_cnt[w] - 1;/@a window flips one bit fewer"
  "stuck_off@s/    if (stuck.exists(row)) begin/    if (1'b0) begin/@stuck bits read their stored value"
  "same_read@s/64'(rd_cnt\[row\]));/64'd0);/@every read of a row flips the same bits"
  "no_wear_rate@s/    real p   = rber \* (1.0 + rber_wear \* real'(pe\[blk\]) \/ real'(endurance));/    real p   = rber;/@worn blocks have no more bit errors"
  "no_wear_prog@s/ - int'(\$floor(prog_wear \* w))//@worn cells program no faster"
  "no_wear_erase@s/\$floor(erase_wear \* w + erase_spread \* runi())/\$floor(erase_spread * runi())/@worn blocks erase no slower"
  "no_cliff@s/          if (n > erase_max || worn\[blk\]) begin/          if (worn[blk]) begin/@an erase never runs out of pulses"
  "worn_prog_ok@s/op_fail = op_fail || bad\[blk\] || worn\[blk\];/op_fail = op_fail || bad[blk];/@a worn-out block takes programs"
  "bad_erase_ok@s/        if (bad\[blk\] || worn\[blk\]) op_fail = 1'b1;/        if (worn[blk]) op_fail = 1'b1;/@an erase of a factory bad block succeeds"
  "no_marker@s/return 8'h00;/return 8'hFF;/@no bad-block marker"
  "pe_lost@s/^    pe\[blk\]++;/    ;/@an erase counts no P/E cycle"
  "tr_fixed@s/      B_READ: t = profile ? tR_BASE + tR_STEP \* real'(rint(5)) : tR;/      B_READ: t = tR;/@read times do not vary"
  "rst_fixed@s/          if (profile) t = (op_kind/          if (1'b0) t = (op_kind/@a reset that stops an operation takes the idle reset time"
  "abort_none@s/      B_PROG: if (!op_fail) begin/      B_PROG: if (1'b0) begin/@a stopped program leaves the page as it was"
  "abort_full@s/if (c\[k\] \&\& runi() < f) v\[k\] = 1'b0;/if (c[k]) v[k] = 1'b0;/@a stopped program has written all its bits"
  "erase_abort_none@s/if (!v\[k\] \&\& runi() < f) v\[k\] = 1'b1;/if (1'b0) v[k] = 1'b1;/@a stopped erase leaves the data as it was"
  "erase_abort_stable@s/          unstable\[blk\] = 1'b1;/          unstable[blk] = 1'b0;/@a stopped erase leaves the block ready for programs"
  "no_order@s/    if (pg < top\[blk\]) rule(/    if (1'b0) rule(/@pages programmed out of order go unreported"
  "nop_plus@s/    if (nop\[row\] > NOP) rule(/    if (nop[row] > NOP + 1) rule(/@one partial program too many goes unreported"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$here/tb/nand_model.sv" "$dir/"
  sed -i "$expr" "$dir/nand_model.sv"
  if cmp -s "$here/tb/nand_model.sv" "$dir/nand_model.sv"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  r="$root/rtl"
  src=(
    "$here/lint/waivers.vlt"
    "$r/common/fifo_sync.sv" "$r/common/cdc_sync_2ff.sv" "$r/common/cdc_async_fifo.sv" "$r/mem/mem_array.sv"
    "$r/csr/gen/nand_regs_pkg.sv" "$r/csr/gen/nand_regs.sv"
    "$r/ecc/bch_pkg.sv" "$r/ecc/bch_enc.sv" "$r/ecc/bch_syn.sv" "$r/ecc/bch_bm.sv" "$r/ecc/bch_chien.sv" "$r/ecc/bch_dec.sv"
    "$r/nand/nand_pkg.sv" "$r/nand/nand_seq.sv" "$r/nand/nand_pbuf.sv" "$r/nand/nand_ctrl.sv"
    "$here/uvm/apb_if.sv" "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv"
    "$here/sva/nand_checker.sv" "$here/sva/nand_bind.sv" "$dir/nand_model.sv" "$here/tb/tb_nand.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_nand \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=busy" "+test=wear" "+test=abort" "+test=rules" "+test=biterr" \
              "+test=random +n=150 +profile=1 +rber_ppm=200"; do
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
