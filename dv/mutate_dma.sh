#!/usr/bin/env bash
# Mutation check for the DMA testbench. Each mutant copies rtl/dma/dma.sv into
# the build directory, plants one bug with sed, builds tb_dma and runs the
# directed test and one random seed. The testbench must fail on every mutant.
# The repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/dma_mut"

# name @ sed expression @ what the bug does (fields split at @)
mutants=(
  "page_split@s/if (to_page < 10'd16) b = to_page\[4:0\];/if (1'b0) b = to_page[4:0];/@bursts not split at 4 KB boundaries"
  "last_strb@s/if ((al_out_left == 22'd1) \&\& (al_eoff != 3'd0))/if ((al_out_left == 22'd1) \&\& 1'b0)/@last beat written with all strobes"
  "shift_dir@s/assign aj_din = {nd_soff - nd_doff,/assign aj_din = {nd_doff - nd_soff,/@aligner shifts the wrong way"
  "prime@s/(nd_soff < nd_doff), nd_doff,/(nd_soff <= nd_doff), nd_doff,/@first beat not primed when the offsets are equal"
  "fence@s/(!nd_fence || wr_idle)/(1'b1 || wr_idle)/@FENCE ignored"
  "credit@s/(rd_space >= RSW'(re_len))/(rd_space >= RSW'(1))/@reads issued without room for their data"
  "drain@s/wire drained   = !m_arvalid \&\& rt_empty/wire drained   = 1'b1 || rt_empty/@ERR raised before outstanding transactions finish"
  "desc_done@s/(m_bresp == OKAY) \&\& wt_jlast) desc_done/(m_bresp == OKAY)) desc_done/@DESC_DONE counts bursts, not descriptors"
  "err_addr@s/err_cause = C_DATA_RD; err_resp = m_rresp; err_addr = rt_dout;/err_cause = C_DATA_RD; err_resp = m_rresp; err_addr = df_addr;/@wrong ERR_ADDR for a data read error"
  "aw_early@s/(wr_avail >= WSW'(we_len))/(wr_avail >= WSW'(1))/@AW issued before its data is buffered"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  mkdir -p "$dir/rtl/dma"
  cp "$root/rtl/dma/dma.sv" "$dir/rtl/dma/dma.sv"
  sed -i "$expr" "$dir/rtl/dma/dma.sv"
  if cmp -s "$root/rtl/dma/dma.sv" "$dir/rtl/dma/dma.sv"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  src=(
    "$here/lint/waivers.vlt"
    "$root/rtl/csr/gen/dma_regs_pkg.sv" "$root/rtl/csr/gen/dma_regs.sv"
    "$root/rtl/common/fifo_sync.sv" "$dir/rtl/dma/dma.sv"
    "$here/tb/axi4_if.sv" "$here/sva/axi4_checker.sv" "$here/tb/dma_tb_pkg.sv" "$here/tb/tb_dma.sv"
  )
  # One object directory for all mutants keeps the build tree small.
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_dma \
    "${src[@]}" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+test=directed" "+test=random +n=100"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 "$base/obj/Vtb_dma" $args +verilator+seed+1) > "$dir/run.log" 2>&1; then
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
